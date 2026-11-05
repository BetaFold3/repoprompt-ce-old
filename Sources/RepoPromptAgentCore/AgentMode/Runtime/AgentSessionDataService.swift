import Foundation
import RepoPromptWorkspace

// MARK: - Agent Session Data Error

enum AgentSessionDataError: Error {
    case invalidFilename(String)
    case decodingFailed(Error)
    case loadFailed(Error)
    case saveFailed(Error)
    case noActiveWorkspace
}

package enum AgentSessionFileCreationPolicy {
    /// The compatibility save may create a genuinely new, lifecycle-absent session when no file
    /// and no tombstone exist (exclusive under the session gate). Never overrides lifecycle or tombstone fences, and
    /// never applies to persistence-state saves (their file must already exist).
    case createIfMissing
    /// A writer targeting an existing incarnation must not recreate an explicitly deleted file.
    case requireExisting
}

/// Immutable, process-local ownership of one durable session incarnation. Callers capture this
/// once when they create or hydrate an editable session and never refresh it after deletion.
package struct AgentSessionPersistenceStamp: Hashable {
    package let sessionID: UUID
    package let workspaceID: UUID
    let deletionGeneration: UInt64
    /// Durable lifecycle incarnation. Always present for editable authority; `nil` only for a
    /// deletion candidate captured from a legacy or unreadable file.
    package let incarnationID: UUID?
    fileprivate let serviceID: UUID
    fileprivate let fileURL: URL
}

/// Full-save authority for one session incarnation and transcript-reset generation.
package struct AgentSessionPersistenceState: Hashable {
    package let stamp: AgentSessionPersistenceStamp
    package let transcriptResetGeneration: UInt64
}

package struct AgentSessionEditableLoad {
    package let session: AgentSession
    package let persistenceState: AgentSessionPersistenceState
}

package struct AgentSessionDeletionCandidate: Hashable {
    let composeTabID: UUID
    let persistenceState: AgentSessionPersistenceState

    package var sessionID: UUID {
        persistenceState.stamp.sessionID
    }

    package var storagePath: String {
        persistenceState.stamp.fileURL.path
    }
}

package enum AgentSessionConditionalDeletionResult: Equatable {
    case deleted
    case alreadyAbsent
    case ownershipChanged
}

package struct AgentSessionSaveCommit {
    package enum Disposition: Equatable {
        case written
        case resetAlreadyCommitted
    }

    package let fileURL: URL
    package let persistenceState: AgentSessionPersistenceState
    package let disposition: Disposition
    /// The stored session this commit wrote; `nil` for `.resetAlreadyCommitted` (no write).
    let committedSession: AgentSession?
}

package enum AgentScheduledSendMutationError: Error, Equatable {
    case sessionNotFound(UUID)
    case unreadableScheduledSend(UUID)
    case staleExpectedUpdatedAt(expected: Date?, actual: Date?)
    case staleExpectedAttempt(
        expected: AgentScheduledSendPersist.Attempt,
        actual: AgentScheduledSendPersist.Attempt?
    )
    case scheduledSendNotDispatching(actual: AgentScheduledSendPersist.State)
    case invalidAcceptedUserItem(expectedItemID: UUID, actualItemID: UUID)
    case acceptedItemNotUser(UUID)
    case invalidDispatchReceipt
    case staleExpectedScheduledSendMember(
        expected: AgentScheduledSendMember,
        actual: AgentScheduledSendMember?
    )
    case staleExpectedFinalizedItem(
        itemID: UUID,
        expected: AgentScheduledSendProvenance,
        actual: AgentScheduledSendProvenance?
    )
    case invalidPersistenceStamp
    case staleDeletionGeneration(expected: UInt64, actual: UInt64)
    case staleTranscriptResetGeneration(expected: UInt64, actual: UInt64)
    case sessionAlreadyExists(UUID)
    /// A durable tombstone retired this session UUID.
    case sessionDeleted(UUID)
    /// A tombstone exists for this UUID but cannot be verified; writes fail closed.
    case unreadableTombstone(UUID)
    /// The persisted envelope's serialization version is not supported by this build.
    case unsupportedSessionEnvelope(UUID, serializationVersion: Int)
    /// The persisted (or supplied) lifecycle member is unreadable and never writable.
    case unreadableLifecycle(UUID)
    /// A compatibility save of an existing file did not carry its loaded lifecycle authority.
    case missingLifecycle(UUID)
    case staleIncarnation(expected: UUID?, actual: UUID?)
    /// Transcript resets commit only through the persistence-state save overload.
    case transcriptResetRequiresPersistenceState
    case transcriptResetGenerationOverflow
    /// Initial creation requires a lifecycle-absent session for this workspace, not a list stub.
    case invalidInitialSession(UUID)
}

package struct AgentScheduledSendFinalizedItemRemoval: Equatable {
    let itemID: UUID
    let receipt: AgentScheduledSendProvenance
}

package enum AgentScheduledSendMutation {
    case upsert(expectedUpdatedAt: Date?, value: AgentScheduledSendPersist)
    case clear(expectedUpdatedAt: Date, completedDispatch: AgentScheduledSendProvenance?)
    case discardUnreadable(expected: AgentScheduledSendJSONValue)
}

package struct AgentScheduledSendMutationResult {
    package enum MetadataIndexStatus: Equatable {
        case updated
        case repairNeeded(String)
    }

    package let session: AgentSession
    let fileURL: URL
    package let metadataIndexStatus: MetadataIndexStatus
}

// MARK: - Agent Session Metadata

/// Lightweight metadata for agent session listing
package struct AgentSessionMeta {
    package let id: UUID
    package let composeTabID: UUID?
    package let name: String
    package let lastModified: Date
    package let itemCount: Int
    package let agentKind: String?
    package let agentModel: String?
    package let lastRunState: String?
    package let parentSessionID: UUID?
    let remoteHostID: String?
    let remoteHostName: String?
    let remoteSessionID: String?
    package let isMCPOriginated: Bool
    /// Session provenance (plan §6.4); `nil` only when built from legacy data
    /// that predates origin tracking.
    package let origin: AgentSessionOrigin?
    let worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary]
    let activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary]
}

private actor AgentSessionDiskWriter {
    private struct PendingWrite {
        var pendingData: Data?
        var isWriting: Bool
        var waiters: [CheckedContinuation<Void, Error>]
    }

    private var pendingByURL: [URL: PendingWrite] = [:]

    func enqueueAndWait(data: Data, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var pending = pendingByURL[url] ?? PendingWrite(
                pendingData: nil,
                isWriting: false,
                waiters: []
            )
            pending.pendingData = data
            pending.waiters.append(continuation)
            let shouldStartWriter = !pending.isWriting
            pending.isWriting = true
            pendingByURL[url] = pending
            if shouldStartWriter {
                Task { await self.drainWrites(for: url) }
            }
        }
    }

    private func drainWrites(for url: URL) async {
        var lastError: Error?
        while true {
            guard var pending = pendingByURL[url] else { return }
            guard let data = pending.pendingData else {
                pending.isWriting = false
                let waiters = pending.waiters
                pendingByURL.removeValue(forKey: url)
                for waiter in waiters {
                    if let lastError {
                        waiter.resume(throwing: lastError)
                    } else {
                        waiter.resume(returning: ())
                    }
                }
                return
            }
            pending.pendingData = nil
            pendingByURL[url] = pending

            let writeResult: Result<Void, Error> = await Task.detached(priority: .utility) {
                do {
                    try data.write(to: url, options: .atomic)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value

            switch writeResult {
            case .success:
                lastError = nil
            case let .failure(error):
                lastError = error
            }
        }
    }
}

// MARK: - Agent Session Data Service

/// An actor that reads/writes AgentSessions from each workspace's "AgentSessions" folder.
///
/// Production composition uses `shared` for every Agent Mode window and MCP entry point, so the
/// per-session persistence gate below is process-wide for app writes. Direct instances remain
/// available to isolated tests.
package actor AgentSessionDataService {
    /// Composed with the app's single production recovery store (one store, one gate, shared by
    /// every window, MCP tool, and the recovery coordinator). XCTest processes keep a storeless
    /// shared instance; tests inject temporary stores explicitly.
    package static let shared = if let store = AgentRecoveryStore.production {
        AgentSessionDataService(
            tombstoneRoot: AgentRecoveryStore.productionRootURL.appendingPathComponent("tombstones", isDirectory: true),
            recoveryStore: store
        )
    } else {
        AgentSessionDataService()
    }

    #if DEBUG
        private var testConditionalDeletionHook: (@Sendable (AgentSessionDeletionCandidate) async throws -> Void)?

        func test_setConditionalDeletionHook(
            _ hook: (@Sendable (AgentSessionDeletionCandidate) async throws -> Void)?
        ) {
            testConditionalDeletionHook = hook
        }
    #endif

    private let persistenceServiceID = UUID()
    /// `<Application Support>/RepoPrompt CE/AgentRecovery/v1/tombstones`. Tombstones are
    /// session-UUID-wide and permanent; isolated tests pass their own root.
    private let tombstoneRoot: URL
    /// Session UUIDs observed with a committed or unreadable tombstone (never removed).
    private var knownTombstonedSessionIDs: Set<UUID> = []
    /// Tombstoned UUIDs whose hidden on-disk residue this service already logged (log once).
    private var loggedTombstonedResidueSessionIDs: Set<UUID> = []
    /// Durable lifecycle last read or written by this service, keyed by canonical file identity.
    /// Valid because this service is the sole writer; refreshed by every gate-held load.
    private var lifecycleByFileKey: [URL: AgentSessionLifecycle] = [:]
    /// Lossless-restart recovery store (Phase 1b). The production store for `shared` outside
    /// XCTest; `nil` keeps recovery discovery, stamping, and deletion cleanup inactive.
    private let recoveryStore: AgentRecoveryStore?
    /// R5 launch evidence adopted from the recovery coordinator's captured previous launch.
    private var coldRestoreLaunchEvidence: AgentRecoveryPreviousLaunch?
    /// Turns this process stamped `unknown` before launch evidence was captured, by session.
    private var provisionalUnknownStampTurnIDs: [UUID: Set<UUID>] = [:]

    /// Default `Workspaces` root for workspaces without a custom storage path, resolved once by
    /// `WorkspaceStorageRoot` (an XCTest process gets its per-process temporary root).
    private let workspacesRoot: URL

    package init(
        tombstoneRoot: URL? = nil,
        recoveryStore: AgentRecoveryStore? = nil,
        workspacesRoot: URL? = nil
    ) {
        self.tombstoneRoot = tombstoneRoot ?? Self.defaultTombstoneRoot()
        self.recoveryStore = recoveryStore
        self.workspacesRoot = WorkspaceStorageRoot.resolve(injected: workspacesRoot).url
    }

    private static func defaultTombstoneRoot() -> URL {
        #if DEBUG
            // Follows the `GlobalSettingsStore` XCTest precedent: test processes (including the
            // shared instance and default-constructed services) never write live Application
            // Support tombstones. Each such instance gets its own temporary root.
            if NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil {
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("RepoPromptCE-XCTest", isDirectory: true)
                    .appendingPathComponent("AgentRecovery-\(UUID().uuidString)", isDirectory: true)
                    .appendingPathComponent("v1", isDirectory: true)
                    .appendingPathComponent("tombstones", isDirectory: true)
            }
        #endif
        return MCPFilesystemConstants.identity.applicationSupportRootURL()
            .appendingPathComponent("AgentRecovery", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("tombstones", isDirectory: true)
    }

    private let encoder = AgentSessionDataService.makeSessionEncoder()
    private let decoder = AgentSessionDataService.makeSessionDecoder()
    private let diskWriter = AgentSessionDiskWriter()
    private static let sidebarStreamMetadataIndexReconciliationDelaySeconds: TimeInterval = 2.0

    private struct MetadataIndexReconciliationTaskState {
        let id: UUID
        let task: Task<Void, Never>
        let delaySeconds: TimeInterval
    }

    private var metadataIndexCacheByFolder: [URL: AgentSessionMetadataIndex] = [:]
    private var metadataIndexReconciliationTasksByFolder: [URL: MetadataIndexReconciliationTaskState] = [:]
    private var metadataIndexReconciledThisProcess: Set<URL> = []
    /// Schema-8 hint inputs: recovery-record facts already obtained by startup discovery and later
    /// commits (never a per-save record read). `nil` facts for a session mean unknown until the
    /// discovery inventory was adopted; afterwards a session without an entry has no record.
    private var recoveryHintRecordFacts: [UUID: (sequence: UInt64, facts: AgentSessionRecoveryHint.RecordFacts)] = [:]
    private var recoveryHintInventoryAdopted = false

    private struct AgentSessionScheduleAuthority {
        var scheduledSend: AgentScheduledSendMember?
        var lastScheduledDispatch: AgentScheduledSendProvenance?
        var protectedAcceptedUserItemsByID: [UUID: AgentChatItem]
        var intentionallyRemovedAcceptedUserItemReceiptsByID: [UUID: AgentScheduledSendProvenance]
    }

    /// Process-local cache of the canonical post-reset snapshot for accidental missing-file
    /// reconstruction. Reset identity itself is durable in the session lifecycle.
    private struct AgentSessionTranscriptResetAuthority {
        let incarnationID: UUID
        let generation: UInt64
        let receipt: AgentSessionTranscriptResetReceipt
        let canonicalSessionSnapshot: Data
    }

    private enum StaleFinalizedItemRemovalPolicy {
        case fail
        case ignore
    }

    /// Process-local authority used by ordinary saves after a schedule mutation/finalization.
    /// Production uses the shared data service, so this both avoids a full JSON parse on the hot
    /// save path and prevents stale VM snapshots from dropping finalized scheduled user items.
    private var scheduleAuthorityByFileURL: [URL: AgentSessionScheduleAuthority] = [:]
    private var transcriptResetAuthorityByFileURL: [URL: AgentSessionTranscriptResetAuthority] = [:]
    /// Latest provider-history import committed through `commitProviderHistoryImport` in this
    /// process, by canonical session file (lossless restart Phase 4). An ordinary save whose payload
    /// carries a different import receipt under the same incarnation is an older snapshot and is
    /// refused, so it can never drop committed imported rows or their native-ID ledger. A transcript
    /// reset commit clears the entry (reset semantics only).
    private var committedHistoryImportByFileURL: [URL: (incarnationID: UUID, importID: UUID)] = [:]
    private var activeSessionPersistence: Set<UUID> = []
    private var sessionPersistenceWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    /// Process-local explicit-deletion evidence keyed by canonical session-file identity. A
    /// recovery context captures the generation before provider handoff; an explicit deletion
    /// (even of an already-absent file) advances it so an older context can never reconstruct.
    private var deletionGenerationsByFileKey: [URL: UInt64] = [:]
    #if DEBUG
        /// Test seam: throws the returned error for recovery finalization attempts.
        private var test_scheduledSendRecoveryFailureInjector: ((AgentScheduledSendAcceptedPayload) -> Error?)?

        /// Installs (or clears with `nil`) the recovery failure injector. Callers that use the
        /// shared instance must clear it during teardown.
        func test_setScheduledSendRecoveryFailureInjector(
            _ injector: (@Sendable (AgentScheduledSendAcceptedPayload) -> Error?)?
        ) {
            test_scheduledSendRecoveryFailureInjector = injector
        }

        /// Test seam: throws the returned error instead of unlinking an existing session file.
        /// The unlink happens after the tombstone commit, so deletion remains logically effective.
        private var test_agentSessionDeletionFailureInjector: ((URL) -> Error?)?

        func test_setAgentSessionDeletionFailureInjector(
            _ injector: (@Sendable (URL) -> Error?)?
        ) {
            test_agentSessionDeletionFailureInjector = injector
        }

        /// Test seam: throws the returned error instead of writing a tombstone.
        private var test_tombstoneWriteFailureInjector: ((UUID) -> Error?)?

        func test_setTombstoneWriteFailureInjector(_ injector: (@Sendable (UUID) -> Error?)?) {
            test_tombstoneWriteFailureInjector = injector
        }

        /// Test seam: throws the returned error instead of replacing or creating a session file.
        private var test_sessionWriteFailureInjector: ((URL) -> Error?)?

        func test_setSessionWriteFailureInjector(_ injector: (@Sendable (URL) -> Error?)?) {
            test_sessionWriteFailureInjector = injector
        }

        /// Test seam: drops this service's process-local lifecycle authority for `fileURL`, as a
        /// service that never observed the destination would have none.
        func test_forgetLifecycleAuthority(for fileURL: URL) {
            let key = canonicalSessionFileKey(fileURL)
            lifecycleByFileKey.removeValue(forKey: key)
            transcriptResetAuthorityByFileURL.removeValue(forKey: key)
        }

        var test_tombstoneRoot: URL {
            tombstoneRoot
        }

        /// Test seam: how many operations are queued behind the session's persistence gate.
        func test_sessionPersistenceWaiterCount(for sessionID: UUID) -> Int {
            sessionPersistenceWaiters[sessionID]?.count ?? 0
        }
    #endif

    private enum AgentSessionMetadataIndexLoadMode {
        case fast
        case backfillIfMissing
        case forceReconcile
    }

    enum FastMetadataRecordsSource: String {
        case memoryIndex
        case diskIndex
    }

    package struct FastMetadataRecordsResult {
        package let records: [AgentSessionMetadataRecord]
        let source: FastMetadataRecordsSource
    }

    // MARK: - Lightweight decode helpers

    private struct AgentSessionLastRunStateHeader: Decodable {
        let lastRunState: String?
    }

    private struct AgentSessionScheduleHeader: Decodable {
        let scheduledSend: AgentScheduledSendMember?
        let lastScheduledDispatch: AgentScheduledSendProvenance?
    }

    /// Envelope version and lifecycle only: the write-side fence for a cache miss.
    private struct AgentSessionLifecycleHeader: Decodable {
        let id: UUID
        let serializationVersion: Int
        let lifecycle: AgentSessionLifecycleMember?

        private enum CodingKeys: String, CodingKey {
            case id
            case serializationVersion
            case lifecycle
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            serializationVersion = try container.decodeIfPresent(Int.self, forKey: .serializationVersion)
                ?? AgentSession.legacyUnversionedSerializationVersion
            lifecycle = try AgentSession.decodeLifecycleMember(from: container, forKey: .lifecycle)
        }
    }

    private struct AgentSessionHeader: Decodable {
        let id: UUID
        let serializationVersion: Int?
        let workspaceID: UUID?
        let composeTabID: UUID?
        let name: String
        let savedAt: Date
        let itemCount: Int?
        let transcriptProjectionCounts: AgentTranscriptProjectionCounts?
        let lastUserMessageAt: Date?
        let agentKind: String?
        let agentModel: String?
        let ohMyPiThinkingSelections: OhMyPiThinkingSelections?
        let agentReasoningEffort: String?
        let lastRunState: String?
        let providerSessionID: String?
        let remoteHost: AgentSessionRemoteHostBinding?
        let autoEditEnabled: Bool
        let codexConversationID: String?
        let codexRolloutPath: String?
        let codexModel: String?
        let codexReasoningEffort: String?
        let codexContextWindow: Int?
        let codexLastTotalTokens: Int?
        let codexTotalTotalTokens: Int?
        let codexMcpSessionKey: String?
        let parentSessionID: UUID?
        let worktreeBindings: [AgentSessionWorktreeBinding]?
        let worktreeMergeOperations: [AgentSessionWorktreeMergeOperation]?
        let pendingHandoffPayload: String?
        let pendingHandoffCreatedAt: Date?
        let pendingHandoffSourceItemID: UUID?
        let pendingHandoffPayloadID: UUID?
        let pendingHandoffDefersProviderLockUntilSend: Bool?
        let isMCPOriginated: Bool?
        let origin: AgentSessionOrigin?
        let profile: AgentSessionProfile?
        let scheduledSend: AgentScheduledSendMember?
        let lastScheduledDispatch: AgentScheduledSendProvenance?
        let lifecycle: AgentSessionLifecycleMember?

        private enum CodingKeys: String, CodingKey {
            case id
            case serializationVersion
            case workspaceID
            case composeTabID
            case name
            case savedAt
            case itemCount
            case transcriptProjectionCounts
            case lastUserMessageAt
            case agentKind
            case agentModel
            case ohMyPiThinkingSelections
            case agentReasoningEffort
            case lastRunState
            case providerSessionID
            case remoteHost
            case autoEditEnabled
            case codexConversationID
            case codexRolloutPath
            case codexModel
            case codexReasoningEffort
            case codexContextWindow
            case codexLastTotalTokens
            case codexTotalTotalTokens
            case codexMcpSessionKey
            case parentSessionID
            case worktreeBindings
            case worktreeMergeOperations
            case pendingHandoffPayload
            case pendingHandoffCreatedAt
            case pendingHandoffSourceItemID
            case pendingHandoffPayloadID
            case pendingHandoffDefersProviderLockUntilSend
            case isMCPOriginated
            case origin
            case profile
            case scheduledSend
            case lastScheduledDispatch
            case lifecycle
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            serializationVersion = try container.decodeIfPresent(Int.self, forKey: .serializationVersion)
            workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
            composeTabID = try container.decodeIfPresent(UUID.self, forKey: .composeTabID)
            name = try container.decode(String.self, forKey: .name)
            savedAt = try container.decode(Date.self, forKey: .savedAt)
            itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
            transcriptProjectionCounts = try container.decodeIfPresent(
                AgentTranscriptProjectionCounts.self,
                forKey: .transcriptProjectionCounts
            )
            lastUserMessageAt = try container.decodeIfPresent(Date.self, forKey: .lastUserMessageAt)
            agentKind = try container.decodeIfPresent(String.self, forKey: .agentKind)
            agentModel = try container.decodeIfPresent(String.self, forKey: .agentModel)
            ohMyPiThinkingSelections = try container.decodeIfPresent(
                OhMyPiThinkingSelections.self,
                forKey: .ohMyPiThinkingSelections
            )?.nilIfEmpty
            agentReasoningEffort = try container.decodeIfPresent(String.self, forKey: .agentReasoningEffort)
            lastRunState = try container.decodeIfPresent(String.self, forKey: .lastRunState)
            providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
            remoteHost = try container.decodeIfPresent(AgentSessionRemoteHostBinding.self, forKey: .remoteHost)
            autoEditEnabled = try container.decode(Bool.self, forKey: .autoEditEnabled)
            // `providerUsage` is captured as raw bytes by `AgentSessionDataCodec`, never decoded here.
            codexConversationID = try container.decodeIfPresent(String.self, forKey: .codexConversationID)
            codexRolloutPath = try container.decodeIfPresent(String.self, forKey: .codexRolloutPath)
            codexModel = try container.decodeIfPresent(String.self, forKey: .codexModel)
            codexReasoningEffort = try container.decodeIfPresent(String.self, forKey: .codexReasoningEffort)
            codexContextWindow = try container.decodeIfPresent(Int.self, forKey: .codexContextWindow)
            codexLastTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexLastTotalTokens)
            codexTotalTotalTokens = try container.decodeIfPresent(Int.self, forKey: .codexTotalTotalTokens)
            codexMcpSessionKey = try container.decodeIfPresent(String.self, forKey: .codexMcpSessionKey)
            parentSessionID = try container.decodeIfPresent(UUID.self, forKey: .parentSessionID)
            worktreeBindings = try container.decodeIfPresent(
                [AgentSessionWorktreeBinding].self,
                forKey: .worktreeBindings
            )
            worktreeMergeOperations = try container.decodeIfPresent(
                [AgentSessionWorktreeMergeOperation].self,
                forKey: .worktreeMergeOperations
            )
            pendingHandoffPayload = try container.decodeIfPresent(String.self, forKey: .pendingHandoffPayload)
            pendingHandoffCreatedAt = try container.decodeIfPresent(Date.self, forKey: .pendingHandoffCreatedAt)
            pendingHandoffSourceItemID = try container.decodeIfPresent(UUID.self, forKey: .pendingHandoffSourceItemID)
            pendingHandoffPayloadID = try container.decodeIfPresent(UUID.self, forKey: .pendingHandoffPayloadID)
            pendingHandoffDefersProviderLockUntilSend = try container.decodeIfPresent(
                Bool.self,
                forKey: .pendingHandoffDefersProviderLockUntilSend
            )
            isMCPOriginated = try container.decodeIfPresent(Bool.self, forKey: .isMCPOriginated)
            origin = try container.decodeIfPresent(AgentSessionOrigin.self, forKey: .origin)
            if container.contains(.profile) {
                guard try !container.decodeNil(forKey: .profile) else {
                    throw DecodingError.valueNotFound(
                        AgentSessionProfile.self,
                        .init(
                            codingPath: container.codingPath + [CodingKeys.profile],
                            debugDescription: "Agent session profile cannot be null"
                        )
                    )
                }
                profile = try container.decode(AgentSessionProfile.self, forKey: .profile)
            } else {
                profile = nil
            }
            scheduledSend = try container.decodeIfPresent(AgentScheduledSendMember.self, forKey: .scheduledSend)
            lastScheduledDispatch = try container.decodeIfPresent(
                AgentScheduledSendProvenance.self,
                forKey: .lastScheduledDispatch
            )
            lifecycle = try AgentSession.decodeLifecycleMember(from: container, forKey: .lifecycle)
        }
    }

    // The normalization and storage-preparation helpers below are static and read only their
    // arguments, so cold hydration can run them off the actor (`loadAgentSessionForHydration`).

    private static func computeLastUserMessageAt(in items: [AgentChatItemPersist]) -> Date? {
        AgentTranscriptIO.lastUserInteractionDate(in: items.map { $0.toItem() })
    }

    private static func computeLastUserMessageAt(in transcript: AgentTranscript) -> Date? {
        AgentTranscriptIO.lastUserInteractionDate(in: transcript)
    }

    private static func computeProjectionCounts(in transcript: AgentTranscript) -> AgentTranscriptProjectionCounts {
        AgentTranscriptProjectionBuilder.projectionCounts(for: transcript)
    }

    private struct NormalizedLoadedSession {
        let runtimeSession: AgentSession
        let persistedSessionToRewrite: AgentSession?
    }

    package enum SavePreparation {
        case canonicalize
        case alreadyCanonicalTranscript
    }

    private struct PreparedSessionMetadata {
        let itemCount: Int?
        let transcriptProjectionCounts: AgentTranscriptProjectionCounts?
        let lastUserMessageAt: Date?
    }

    private static func preparedSessionMetadata(
        transcript: AgentTranscript?,
        workingItems: [AgentChatItem],
        existingItemCount: Int?,
        existingProjectionCounts: AgentTranscriptProjectionCounts?,
        existingLastUserMessageAt: Date?,
        trustedCanonicalItemCount: Int? = nil,
        precomputedProjectionCounts: AgentTranscriptProjectionCounts? = nil,
        preserveProvidedValues: Bool
    ) -> PreparedSessionMetadata {
        if let transcript {
            // `precomputedProjectionCounts` must come from the full projection paired with `transcript`.
            let computedProjectionCounts = precomputedProjectionCounts ?? computeProjectionCounts(in: transcript)
            return PreparedSessionMetadata(
                itemCount: trustedCanonicalItemCount ?? computedProjectionCounts.canonicalVisibleRowCount,
                transcriptProjectionCounts: computedProjectionCounts,
                lastUserMessageAt: preserveProvidedValues ? (existingLastUserMessageAt ?? computeLastUserMessageAt(in: transcript)) : computeLastUserMessageAt(in: transcript)
            )
        }
        guard !workingItems.isEmpty else {
            return PreparedSessionMetadata(
                itemCount: preserveProvidedValues ? existingItemCount : nil,
                transcriptProjectionCounts: preserveProvidedValues ? existingProjectionCounts : nil,
                lastUserMessageAt: preserveProvidedValues ? existingLastUserMessageAt : nil
            )
        }
        let fallbackItemCount = preserveProvidedValues ? (existingItemCount ?? workingItems.count) : workingItems.count
        let fallbackProjectionCounts = preserveProvidedValues
            ? (existingProjectionCounts ?? .init(
                canonicalVisibleRowCount: fallbackItemCount,
                defaultPresentedRowCount: fallbackItemCount
            ))
            : .init(
                canonicalVisibleRowCount: fallbackItemCount,
                defaultPresentedRowCount: fallbackItemCount
            )
        return PreparedSessionMetadata(
            itemCount: fallbackItemCount,
            transcriptProjectionCounts: fallbackProjectionCounts,
            lastUserMessageAt: preserveProvidedValues ? (existingLastUserMessageAt ?? AgentTranscriptIO.lastUserInteractionDate(in: workingItems)) : AgentTranscriptIO.lastUserInteractionDate(in: workingItems)
        )
    }

    private static func sessionPreparedForStorage(
        _ session: AgentSession,
        fileURL: URL? = nil,
        savedAt: Date? = nil,
        preparation: SavePreparation = .canonicalize,
        trustedCanonicalItemCount: Int? = nil
    ) -> AgentSession {
        var stored = session
        let lastRunState = stored.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
        // Counts from the persistent pipeline's full projection paired with the stored transcript.
        var persistedProjectionCounts: AgentTranscriptProjectionCounts?
        var workingItemsCache: [AgentChatItem]?
        func workingItems() -> [AgentChatItem] {
            if let workingItemsCache {
                return workingItemsCache
            }
            let items = stored.items.map { $0.toItem() }
            workingItemsCache = items
            return items
        }

        // Both preparations build and persist the transcript the same way; `preparation` only decides
        // whether provided metadata is preserved below.
        if stored.transcript == nil {
            let canonicalWorkingItems = workingItems()
            if !canonicalWorkingItems.isEmpty {
                let nextSequenceIndex = max((canonicalWorkingItems.map(\.sequenceIndex).max() ?? -1) + 1, 0)
                stored.transcript = AgentTranscriptIO.buildTranscript(
                    from: canonicalWorkingItems,
                    terminalState: lastRunState,
                    nextSequenceIndex: nextSequenceIndex,
                    policy: .canonical
                )
            }
        }
        if let transcript = stored.transcript {
            let persisted = AgentTranscriptPolicyPipeline.persistedTranscript(from: transcript)
            stored.transcript = persisted.transcript
            persistedProjectionCounts = AgentTranscriptProjectionBuilder.projectionCounts(for: persisted.projection)
        }
        stored.items = []
        stored.serializationVersion = AgentSession.currentSerializationVersion
        if let fileURL {
            stored.fileURL = fileURL
        }
        if let savedAt {
            stored.savedAt = savedAt
        }
        let metadata = preparedSessionMetadata(
            transcript: stored.transcript,
            workingItems: workingItemsCache ?? [],
            existingItemCount: stored.itemCount,
            existingProjectionCounts: stored.transcriptProjectionCounts,
            existingLastUserMessageAt: stored.lastUserMessageAt,
            trustedCanonicalItemCount: trustedCanonicalItemCount,
            precomputedProjectionCounts: persistedProjectionCounts,
            preserveProvidedValues: preparation == .alreadyCanonicalTranscript
        )
        stored.itemCount = metadata.itemCount
        stored.transcriptProjectionCounts = metadata.transcriptProjectionCounts
        stored.lastUserMessageAt = metadata.lastUserMessageAt
        return stored
    }

    /// Why a gate-held load runs (F-7). Only `coldRestore` treats the file as the previous
    /// execution's evidence: it stamps open turns, restores accepted bubbles, and maps an active
    /// saved run state to its cold-restored form. `storageMutation` (schedule mutation, repair,
    /// cancellation and finalization, same-launch resync, rename, read-only tool loads, metadata
    /// recovery) decodes and migrates only: an open turn a live owner of this launch may still be
    /// running is never cancelled, stamped, or rewritten as interrupted.
    enum LoadPurpose: Equatable {
        case coldRestore
        case storageMutation
    }

    /// `assigningLifecycle` adds migration identity to the runtime session; the storage form then
    /// differs from the decoded legacy session, so identity joins (or forces) one replacement.
    private static func normalizeLoadedSession(
        _ session: AgentSession,
        fileURL: URL,
        purpose: LoadPurpose,
        assigningLifecycle: AgentSessionLifecycle? = nil,
        interruptionContext: AgentColdRestoreInterruptionContext? = nil
    ) -> NormalizedLoadedSession {
        var runtimeSession = runtimeNormalizedLoadedSession(
            session,
            fileURL: fileURL,
            purpose: purpose,
            interruptionContext: interruptionContext
        )
        if let assigningLifecycle {
            runtimeSession.lifecycle = .v1(assigningLifecycle)
        }
        let storage = storageNormalizedLoadedSession(session, runtimeSession: runtimeSession, fileURL: fileURL)
        return NormalizedLoadedSession(
            runtimeSession: runtimeSession,
            persistedSessionToRewrite: storage.needsRewrite ? storage.persistedSession : nil
        )
    }

    /// The runtime half of `normalizeLoadedSession`: the in-memory session a load returns.
    private static func runtimeNormalizedLoadedSession(
        _ session: AgentSession,
        fileURL: URL,
        purpose: LoadPurpose,
        interruptionContext: AgentColdRestoreInterruptionContext? = nil
    ) -> AgentSession {
        let isColdRestore = purpose == .coldRestore
        // A storage mutation never applies prior-execution evidence.
        let interruptionContext = isColdRestore ? interruptionContext : nil
        let policy = AgentTranscriptImportPolicy.canonical
        let persistedLastRunState = session.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
        // F-7: an active saved run state that a live run of the current launch still owns is not a
        // previous execution's state, so a second owner's cold hydration keeps it as saved.
        let keepsLiveRunState = interruptionContext?.hasCurrentLaunchLiveRun == true
        let restoredLastRunStateRaw = isColdRestore && !keepsLiveRunState
            ? AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(session.lastRunState)
            : session.lastRunState
        let repairTerminalState = (persistedLastRunState?.isActive == true) ? nil : persistedLastRunState
        let importTerminalState = persistedLastRunState
        let repairContext = AgentTranscriptQualityRepair.Context.coldRestore(agentKindRaw: session.agentKind)
        let storedTranscript = session.transcript
        var workingItems: [AgentChatItem] = {
            if session.items.isEmpty, let storedTranscript {
                return AgentTranscriptIO.workingSourceItems(from: storedTranscript)
            }
            return session.items.map { $0.toItem() }
        }()
        let repairedWorkingCount: Int = if let repairTerminalState {
            AgentTranscriptQualityRepair.finalizePendingTerminalTools(
                in: &workingItems,
                terminalState: repairTerminalState,
                context: repairContext,
                nonToolBoundary: 200,
                protectedItemIDs: session.providerHistoryRecovery?.claudeLocalItemIDs ?? []
            )
        } else {
            0
        }
        var nextSequenceIndex = max(
            storedTranscript?.nextSequenceIndex ?? 0,
            (workingItems.map(\.sequenceIndex).max() ?? -1) + 1
        )
        // R1a: an accepted earlier-launch intent without its saved bubble gets it restored once,
        // under its deterministic item ID, in the same normalization the load commits.
        let presentItemIDs = Set(workingItems.map(\.id))
            .union((storedTranscript?.turns ?? []).compactMap { $0.request?.id })
        let restoredBubbles = interruptionContext?.missingAcceptedBubbles(
            lifecycle: session.lifecycle?.lifecycle,
            presentItemIDs: presentItemIDs
        ) ?? []
        for var bubble in restoredBubbles {
            bubble.sequenceIndex = nextSequenceIndex
            nextSequenceIndex += 1
            workingItems.append(bubble)
        }
        let normalizedTranscript: AgentTranscript?
        if let storedTranscript {
            let shouldRebuildFromWorkingItems = repairedWorkingCount > 0
                || !restoredBubbles.isEmpty
                || AgentTranscriptIO.containsRowsExcludedByPolicy(in: storedTranscript, policy: policy)
                || (repairTerminalState != nil && AgentTranscriptQualityRepair.terminalMetadataRepairNeeded(in: storedTranscript))
            if shouldRebuildFromWorkingItems {
                normalizedTranscript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                    existingTranscript: storedTranscript,
                    workingItems: workingItems,
                    terminalState: importTerminalState,
                    nextSequenceIndex: nextSequenceIndex,
                    policy: policy
                )
            } else {
                normalizedTranscript = AgentTranscriptIO.runtimeNormalizedTranscript(storedTranscript)
            }
        } else if !workingItems.isEmpty {
            normalizedTranscript = AgentTranscriptIO.buildTranscript(
                from: workingItems,
                terminalState: importTerminalState,
                nextSequenceIndex: nextSequenceIndex,
                policy: policy
            )
        } else {
            normalizedTranscript = nil
        }
        let runtimeTranscript = normalizedTranscript.map {
            let runtimeNormalized = AgentTranscriptPolicyPipeline.runtimeTranscriptOnly($0)
            guard isColdRestore else { return runtimeNormalized }
            return AgentSessionRestoreSupport.sanitizeColdRestoredTranscript(
                runtimeNormalized,
                interruptionContext: interruptionContext,
                unacceptedDeliveries: interruptionContext?.unacceptedDeliveries(lifecycle: session.lifecycle?.lifecycle) ?? [:],
                protectedItemIDs: session.providerHistoryRecovery?.claudeLocalItemIDs ?? []
            )
        }
        let runtimeWorkingItems = runtimeTranscript.map(AgentTranscriptIO.workingSourceItems(from:)) ?? workingItems
        var runtimeSession = session
        runtimeSession.serializationVersion = AgentSession.currentSerializationVersion
        runtimeSession.fileURL = fileURL
        runtimeSession.lastRunState = restoredLastRunStateRaw
        runtimeSession.transcript = runtimeTranscript
        runtimeSession.items = runtimeWorkingItems.map {
            AgentChatItemPersist(from: $0, sanitizeToolResults: false)
        }
        if let runtimeTranscript {
            let projectionCounts = computeProjectionCounts(in: runtimeTranscript)
            runtimeSession.itemCount = projectionCounts.canonicalVisibleRowCount
            runtimeSession.transcriptProjectionCounts = projectionCounts
            runtimeSession.lastUserMessageAt = computeLastUserMessageAt(in: runtimeTranscript)
        } else if !runtimeWorkingItems.isEmpty {
            runtimeSession.itemCount = runtimeWorkingItems.count
            runtimeSession.transcriptProjectionCounts = .init(
                canonicalVisibleRowCount: runtimeWorkingItems.count,
                defaultPresentedRowCount: runtimeWorkingItems.count
            )
            runtimeSession.lastUserMessageAt = computeLastUserMessageAt(in: runtimeSession.items)
        }
        return runtimeSession
    }

    private struct StorageNormalizedLoadedSession {
        let persistedSession: AgentSession
        let needsRewrite: Bool
    }

    /// The storage half of `normalizeLoadedSession`: the canonical stored form of `runtimeSession`
    /// and whether the decoded `session` differs from it. The rewrite decision never compares
    /// worktree merge operations; the stored form carries `runtimeSession`'s operations as given.
    private static func storageNormalizedLoadedSession(
        _ session: AgentSession,
        runtimeSession: AgentSession,
        fileURL: URL
    ) -> StorageNormalizedLoadedSession {
        let persistedSession = sessionPreparedForStorage(
            runtimeSession,
            fileURL: fileURL,
            savedAt: session.savedAt,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: runtimeSession.itemCount
        )
        let needsRewrite = session.serializationVersion < AgentSession.currentSerializationVersion
            || !session.items.isEmpty
            || session.lastRunState != persistedSession.lastRunState
            || session.transcript != persistedSession.transcript
            || session.itemCount != persistedSession.itemCount
            || session.transcriptProjectionCounts != persistedSession.transcriptProjectionCounts
            || session.lastUserMessageAt != persistedSession.lastUserMessageAt
            || session.lifecycle != persistedSession.lifecycle
        return StorageNormalizedLoadedSession(persistedSession: persistedSession, needsRewrite: needsRewrite)
    }

    /// Every session-file replacement goes through here (callers hold the session gate).
    private func writeDataAtomically(_ data: Data, to fileURL: URL) async throws {
        #if DEBUG
            if let injected = test_sessionWriteFailureInjector?(fileURL) {
                throw injected
            }
        #endif
        try await diskWriter.enqueueAndWait(data: data, url: fileURL)
    }

    // MARK: - Metadata Index Helpers

    /// Metadata-index cache, reconciliation and once-per-process keys share the session-file
    /// directory identity, so a save through a stamp's resolved folder and a listing through the
    /// workspace's own spelling of that folder use one cache entry.
    private func canonicalMetadataFolderKey(_ folder: URL) -> URL {
        resolvedExistingDirectoryKey(folder) ?? folder.standardizedFileURL
    }

    /// `realpath(3)` of an existing directory (symlinks, `/var` vs `/private/var`, on-disk case);
    /// `nil` when it cannot be resolved (for example, an absent folder).
    private func resolvedExistingDirectoryKey(_ directory: URL) -> URL? {
        let resolvedPath: String? = directory.standardizedFileURL.withUnsafeFileSystemRepresentation { representation in
            guard let representation, let resolved = realpath(representation, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return resolvedPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func metadataIndexFileURL(forAgentSessionsFolder folder: URL) -> URL {
        folder.appendingPathComponent("AgentSessionIndex.json")
    }

    private func agentSessionFilename(for id: UUID) -> String {
        "AgentSession-\(id.uuidString).json"
    }

    private func agentSessionFileURL(id: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent(agentSessionFilename(for: id))
    }

    private func agentSessionID(fromFilename filename: String) -> UUID? {
        guard filename.starts(with: "AgentSession-"), filename.hasSuffix(".json") else { return nil }
        let prefixLength = "AgentSession-".count
        let suffixLength = ".json".count
        guard filename.count > prefixLength + suffixLength else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: prefixLength)
        let end = filename.index(filename.endIndex, offsetBy: -suffixLength)
        return UUID(uuidString: String(filename[start ..< end]))
    }

    private func metadataResourceValues(for fileURL: URL) -> (size: Int64?, modified: Date?) {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize.map(Int64.init)
        return (size, values?.contentModificationDate)
    }

    private func metadataRecord(from session: AgentSession, fileURL: URL) -> AgentSessionMetadataRecord {
        let values = metadataResourceValues(for: fileURL)
        return AgentSessionMetadataRecord.record(
            from: session,
            fileURL: fileURL,
            observedFileSize: values.size,
            observedFileModificationDate: values.modified,
            recoveryRecordFacts: recoveryHintRecordFacts(for: session.id)
        )
    }

    /// Known recovery-record facts for the hint, or `nil` (unknown) before the discovery inventory
    /// was adopted and nothing was committed for the session since.
    private func recoveryHintRecordFacts(for sessionID: UUID) -> AgentSessionRecoveryHint.RecordFacts? {
        if let known = recoveryHintRecordFacts[sessionID] { return known.facts }
        return recoveryHintInventoryAdopted ? .absent : nil
    }

    /// Adopts the recovery-record inventory startup discovery already read (schema-8 hint input).
    /// Facts a commit already reported are newer and kept.
    package func adoptRecoveryHintInventory(_ entries: [AgentRecoveryDiscoveryEntry]) {
        for entry in entries {
            let sessionID: UUID
            let facts: AgentSessionRecoveryHint.RecordFacts
            switch entry {
            case let .supported(discovered):
                sessionID = discovered.record.sessionID
                facts = .make(from: discovered.record)
            case let .preserved(preserved):
                guard let id = preserved.sessionID else { continue }
                sessionID = id
                facts = .unreadable
            }
            if recoveryHintRecordFacts[sessionID] == nil {
                recoveryHintRecordFacts[sessionID] = (0, facts)
            }
        }
        recoveryHintInventoryAdopted = true
    }

    /// A committed recovery-record change (published in commit order by `sequence`). Updates the
    /// hint of an already-loaded index entry and rewrites that index only when the hint changed, so
    /// ordinary composer or question writes never rewrite the index.
    package func noteRecoveryRecordCommitted(
        sessionID: UUID,
        sequence: UInt64,
        facts: AgentSessionRecoveryHint.RecordFacts
    ) async {
        if let known = recoveryHintRecordFacts[sessionID], known.sequence >= sequence { return }
        recoveryHintRecordFacts[sessionID] = (sequence, facts)
        for folder in Array(metadataIndexCacheByFolder.keys) {
            // Re-read per folder: an earlier write may have suspended.
            guard let index = metadataIndexCacheByFolder[folder],
                  let position = index.entries.firstIndex(where: { $0.id == sessionID })
            else { continue }
            let entry = index.entries[position]
            let hint = AgentSessionRecoveryHint.make(
                unresolvedInterruption: entry.hasUnresolvedInterruption,
                reason: entry.recoveryHint.reason,
                schedule: entry.scheduledSendSummary,
                record: facts
            )
            guard hint != entry.recoveryHint else { continue }
            var updated = index
            updated.entries[position].recoveryHint = hint
            metadataIndexCacheByFolder[folder] = updated
            // The session files remain authoritative; a failed index write is repaired later.
            try? await writeMetadataIndex(updated, folder: folder)
        }
    }

    private func readMetadataIndexIfAvailable(folder: URL, preferCache: Bool = true) async -> AgentSessionMetadataIndex? {
        #if DEBUG
            let readStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let key = canonicalMetadataFolderKey(folder)
        if preferCache, let cached = metadataIndexCacheByFolder[key] {
            guard cached.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                return nil
            }
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.memoryRead status=hit entries=\(cached.entries.count) quarantined=\(cached.quarantinedFiles.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                    )
                }
            #endif
            return cached
        }
        let fileURL = metadataIndexFileURL(forAgentSessionsFolder: folder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.diskRead status=missing duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                    )
                }
            #endif
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            guard index.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                #if DEBUG
                    if let readStartMS {
                        WorkspaceRestorePerfLog.log(
                            "agentSessionIndex.diskRead status=schemaMismatch entries=\(index.entries.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                        )
                    }
                #endif
                return nil
            }
            metadataIndexCacheByFolder[key] = index
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.diskRead status=hit entries=\(index.entries.count) quarantined=\(index.quarantinedFiles.count) bytes=\(data.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS))"
                    )
                }
            #endif
            return index
        } catch {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            #if DEBUG
                if let readStartMS {
                    WorkspaceRestorePerfLog.log(
                        "agentSessionIndex.diskRead status=error duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: readStartMS)) error=\(String(describing: error))"
                    )
                }
            #endif
            return nil
        }
    }

    private func writeMetadataIndex(_ index: AgentSessionMetadataIndex, folder: URL) async throws {
        #if DEBUG
            let writeStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let key = canonicalMetadataFolderKey(folder)
        var normalized = index
        normalized.schemaVersion = AgentSessionMetadataIndex.currentSchemaVersion
        normalized.entries = normalized.entries.sortedForAgentSessionMetadataIndex()
        let data = try encoder.encode(normalized)
        metadataIndexCacheByFolder[key] = normalized
        try data.write(to: metadataIndexFileURL(forAgentSessionsFolder: folder), options: .atomic)
        #if DEBUG
            AgentModePerfDiagnostics.durationEvent(
                "cleanup.metadata.writeIndex",
                startMS: writeStartMS,
                fields: [
                    "entries": String(normalized.entries.count),
                    "quarantined": String(normalized.quarantinedFiles.count)
                ]
            )
        #endif
    }

    private func upsertMetadataRecordReporting(
        _ record: AgentSessionMetadataRecord,
        folder: URL
    ) async -> Result<Void, Error> {
        do {
            let key = canonicalMetadataFolderKey(folder)
            var index: AgentSessionMetadataIndex = if let cached = metadataIndexCacheByFolder[key] {
                cached
            } else if let existing = await readMetadataIndexIfAvailable(folder: folder) {
                existing
            } else {
                AgentSessionMetadataIndex()
            }
            index.entries.removeAll { existing in
                existing.id == record.id || existing.filename == record.filename
            }
            index.entries.append(record)
            index.generatedAt = Date()
            metadataIndexCacheByFolder[key] = index
            try await writeMetadataIndex(index, folder: folder)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func upsertMetadataRecord(_ record: AgentSessionMetadataRecord, folder: URL) async {
        _ = await upsertMetadataRecordReporting(record, folder: folder)
        // Session files remain authoritative; a later backfill/reconcile can repair the index.
    }

    private func upsertMetadataRecordIfIndexPresent(_ session: AgentSession, fileURL: URL) async {
        let folder = fileURL.deletingLastPathComponent()
        guard var index = await readMetadataIndexIfAvailable(folder: folder) else { return }
        let record = metadataRecord(from: session, fileURL: fileURL)
        if let existing = index.entries.first(where: { $0.id == record.id }),
           existing.matchesIndexedSessionMetadata(record)
        {
            return
        }
        index.entries.removeAll { existing in
            existing.id == record.id || existing.filename == record.filename
        }
        index.entries.append(record)
        index.generatedAt = Date()
        try? await writeMetadataIndex(index, folder: folder)
    }

    private func removeMetadataRecords(
        matching shouldRemove: (AgentSessionMetadataRecord) -> Bool,
        folder: URL
    ) async {
        #if DEBUG
            let removeStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
            var debugEntriesBefore = 0
            var debugEntriesAfter = 0
            var debugChanged = false
            defer {
                AgentModePerfDiagnostics.durationEvent(
                    "cleanup.metadata.removeRecords",
                    startMS: removeStartMS,
                    fields: [
                        "entriesBefore": String(debugEntriesBefore),
                        "entriesAfter": String(debugEntriesAfter),
                        "changed": String(debugChanged)
                    ]
                )
            }
        #endif
        guard var index = await readMetadataIndexIfAvailable(folder: folder) else { return }
        let originalCount = index.entries.count
        #if DEBUG
            debugEntriesBefore = originalCount
            debugEntriesAfter = originalCount
        #endif
        index.entries.removeAll(where: shouldRemove)
        #if DEBUG
            debugEntriesAfter = index.entries.count
            debugChanged = index.entries.count != originalCount
        #endif
        guard index.entries.count != originalCount else { return }
        index.generatedAt = Date()
        try? await writeMetadataIndex(index, folder: folder)
    }

    private func agentSessionFiles(in folder: URL) throws -> [URL] {
        #if DEBUG
            let scanStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        // Residue of a committed deletion (unlink failed after the tombstone) is not a session.
        let tombstoned = try tombstonedSessionIDs()
        let jsonFiles = contents.filter { fileURL in
            fileURL.pathExtension.lowercased() == "json"
                && fileURL.lastPathComponent.starts(with: "AgentSession-")
                && agentSessionID(fromFilename: fileURL.lastPathComponent).map {
                    !isTombstonedResidue(fileURL, sessionID: $0, tombstoned: tombstoned)
                } ?? true
        }
        let sorted = jsonFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate > rhsDate
        }
        #if DEBUG
            if let scanStartMS {
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.fileScan scannedSessionFiles=\(sorted.count) directoryEntries=\(contents.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: scanStartMS))"
                )
            }
        #endif
        return sorted
    }

    private func metadataIndexNeedsFilenameReconciliation(_ index: AgentSessionMetadataIndex, folder: URL) throws -> Bool {
        #if DEBUG
            let reconcileCheckStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let fileNames = try Set(agentSessionFiles(in: folder).map(\.lastPathComponent))
        let indexedNames = Set(index.entries.map(\.filename))
        let needsReconciliation = fileNames != indexedNames
        #if DEBUG
            if let reconcileCheckStartMS {
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.reconcileCheck needsRebuild=\(needsReconciliation) scannedSessionFiles=\(fileNames.count) indexedEntries=\(indexedNames.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: reconcileCheckStartMS))"
                )
            }
        #endif
        return needsReconciliation
    }

    private func rebuildMetadataIndex(folder: URL) async throws -> AgentSessionMetadataIndex {
        let key = canonicalMetadataFolderKey(folder)
        #if DEBUG
            let rebuildStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let now = Date()
        let files = try agentSessionFiles(in: folder)
        var records: [AgentSessionMetadataRecord] = []
        var quarantinedFiles: [AgentSessionMetadataQuarantineRecord] = []
        records.reserveCapacity(files.count)

        for fileURL in files {
            let values = metadataResourceValues(for: fileURL)
            do {
                // Load a lightweight stub (transcript=nil). Transcript-derived v5 fields
                // (duration primitives, keyPaths, toolCount, activity bounds) are left empty
                // here and computed on demand by the `history` tool — see
                // `AgentSessionMetadataRecord.enrichingTranscriptDerivedFields(from:)`. This
                // keeps the shared index rebuild — which feeds the agent-mode sidebar and
                // workspace restore — from decoding every full session transcript just to
                // precompute fields only history consumes. The save/load path still populates
                // these fields for free for sessions touched through normal app use.
                let stub = try await loadAgentSessionStub(
                    from: fileURL,
                    recoverMissingMetadata: false,
                    persistRecoveredMetadata: false
                )
                // Schema-8 hint: joined with the recovery inventory already in memory; the stub's
                // transcript part stays unknown (no transcript is decoded for hints).
                records.append(
                    AgentSessionMetadataRecord.record(
                        from: stub,
                        fileURL: fileURL,
                        observedFileSize: values.size,
                        observedFileModificationDate: values.modified,
                        lastIndexedAt: now,
                        recoveryRecordFacts: recoveryHintRecordFacts(for: stub.id)
                    )
                )
            } catch {
                quarantinedFiles.append(
                    AgentSessionMetadataQuarantineRecord(
                        filename: fileURL.lastPathComponent,
                        observedFileSize: values.size,
                        observedFileModificationDate: values.modified,
                        errorDescription: String(describing: error),
                        lastAttemptedAt: now
                    )
                )
            }
        }

        let index = AgentSessionMetadataIndex(
            generatedAt: now,
            lastReconciledAt: now,
            entries: records.sortedForAgentSessionMetadataIndex(),
            quarantinedFiles: quarantinedFiles
        )
        if files.isEmpty,
           !FileManager.default.fileExists(atPath: metadataIndexFileURL(forAgentSessionsFolder: folder).path)
        {
            // No sessions and no index on disk: an empty index file would describe nothing, so
            // keep it in memory only. The first saved session writes the index.
            metadataIndexCacheByFolder[key] = index
        } else {
            try? await writeMetadataIndex(index, folder: folder)
        }
        metadataIndexReconciledThisProcess.insert(key)
        #if DEBUG
            if let rebuildStartMS {
                WorkspaceRestorePerfLog.log(
                    "agentSessionIndex.rebuild scannedSessionFiles=\(files.count) records=\(records.count) quarantined=\(quarantinedFiles.count) duration=\(WorkspaceRestorePerfLog.formatElapsedMS(since: rebuildStartMS))"
                )
            }
        #endif
        return index
    }

    private func reconcileMetadataIndex(folder: URL) async throws -> AgentSessionMetadataIndex {
        try await rebuildMetadataIndex(folder: folder)
    }

    private func scheduleMetadataIndexReconciliationIfNeeded(
        folder: URL,
        delaySeconds: TimeInterval = 0,
        reason: String = "metadataIndexBackfill",
        workspaceID: UUID? = nil
    ) {
        let key = canonicalMetadataFolderKey(folder)
        let alreadyReconciled = metadataIndexReconciledThisProcess.contains(key)
        let existingTaskState = metadataIndexReconciliationTasksByFolder[key]
        let alreadyScheduled = existingTaskState != nil
        let effectiveDelaySeconds = max(delaySeconds, 0)
        let promotesDelayedReconciliation = existingTaskState.map {
            $0.delaySeconds > 0 && effectiveDelaySeconds == 0
        } ?? false
        let willSchedule = !alreadyReconciled && (!alreadyScheduled || promotesDelayedReconciliation)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "agentSessionIndex.reconcileScheduled",
                fields: [
                    "workspaceID": WorkspaceRestorePerfLog.shortID(workspaceID),
                    "delayMS": "\(Int((effectiveDelaySeconds * 1000).rounded()))",
                    "reason": reason,
                    "alreadyScheduled": "\(alreadyScheduled)",
                    "alreadyReconciled": "\(alreadyReconciled)",
                    "scheduled": "\(willSchedule)"
                ]
            )
        #endif
        guard willSchedule else { return }
        if promotesDelayedReconciliation {
            existingTaskState?.task.cancel()
        }
        let taskID = UUID()
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await reconcileMetadataIndexInBackground(
                folder: folder,
                delaySeconds: effectiveDelaySeconds,
                taskID: taskID
            )
        }
        metadataIndexReconciliationTasksByFolder[key] = MetadataIndexReconciliationTaskState(
            id: taskID,
            task: task,
            delaySeconds: effectiveDelaySeconds
        )
    }

    private func reconcileMetadataIndexInBackground(
        folder: URL,
        delaySeconds: TimeInterval = 0,
        taskID: UUID
    ) async {
        let key = canonicalMetadataFolderKey(folder)
        defer {
            if metadataIndexReconciliationTasksByFolder[key]?.id == taskID {
                metadataIndexReconciliationTasksByFolder.removeValue(forKey: key)
            }
        }
        if delaySeconds > 0 {
            let nanoseconds = UInt64(min(delaySeconds, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
        }
        do {
            _ = try await reconcileMetadataIndex(folder: folder)
        } catch {
            // Best-effort: session files remain authoritative, and explicit force-reconcile can repair later.
        }
    }

    private func metadataIndex(
        for workspace: some AgentWorkspaceStorageReference,
        mode: AgentSessionMetadataIndexLoadMode
    ) async throws -> AgentSessionMetadataIndex? {
        // A workspace that never saved a session has no folder: nothing to read, rebuild, or index.
        guard let folder = agentSessionsFolderIfExists(for: workspace) else { return nil }
        switch mode {
        case .fast:
            return await readMetadataIndexIfAvailable(folder: folder)
        case .backfillIfMissing:
            if let index = await readMetadataIndexIfAvailable(folder: folder) {
                scheduleMetadataIndexReconciliationIfNeeded(folder: folder)
                return index
            }
            return try await rebuildMetadataIndex(folder: folder)
        case .forceReconcile:
            return try await reconcileMetadataIndex(folder: folder)
        }
    }

    package func fastMetadataRecordsIfAvailable(for workspace: some AgentWorkspaceStorageReference) async throws -> FastMetadataRecordsResult? {
        guard let folder = agentSessionsFolderIfExists(for: workspace) else { return nil }
        let key = canonicalMetadataFolderKey(folder)
        if let cached = metadataIndexCacheByFolder[key] {
            guard cached.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                return nil
            }
            return try FastMetadataRecordsResult(
                records: excludingTombstoned(cached.entries.sortedForAgentSessionMetadataIndex()),
                source: .memoryIndex
            )
        }

        let fileURL = metadataIndexFileURL(forAgentSessionsFolder: folder)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let index = try decoder.decode(AgentSessionMetadataIndex.self, from: data)
            guard index.schemaVersion == AgentSessionMetadataIndex.currentSchemaVersion else {
                metadataIndexCacheByFolder.removeValue(forKey: key)
                return nil
            }
            metadataIndexCacheByFolder[key] = index
            return try FastMetadataRecordsResult(
                records: excludingTombstoned(index.entries.sortedForAgentSessionMetadataIndex()),
                source: .diskIndex
            )
        } catch {
            metadataIndexCacheByFolder.removeValue(forKey: key)
            return nil
        }
    }

    package func metadataRecordForSessionID(_ id: UUID, for workspace: some AgentWorkspaceStorageReference) async throws -> AgentSessionMetadataRecord? {
        let folder = agentSessionsFolderURL(for: workspace)
        let fileURL = agentSessionFileURL(id: id, in: folder)
        guard try tombstoneState(for: id) == .absent,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return nil
        }
        let stub = try await loadAgentSessionStub(
            from: fileURL,
            recoverMissingMetadata: false,
            persistRecoveredMetadata: false
        )
        return metadataRecord(from: stub, fileURL: fileURL)
    }

    private func metadataRecords(
        for workspace: some AgentWorkspaceStorageReference,
        limit: Int? = nil
    ) async throws -> [AgentSessionMetadataRecord] {
        let index = try await metadataIndex(for: workspace, mode: .backfillIfMissing)
        let records = try excludingTombstoned(index?.entries.sortedForAgentSessionMetadataIndex() ?? [])
        guard let limit else { return records }
        return Array(records.prefix(max(limit, 0)))
    }

    func indexedAgentSessionMetadataRecords(for workspace: some AgentWorkspaceStorageReference) async throws -> [AgentSessionMetadataRecord] {
        try await metadataRecords(for: workspace)
    }

    func sidebarStreamMetadataRecords(for workspace: some AgentWorkspaceStorageReference) async throws -> [AgentSessionMetadataRecord] {
        guard let folder = agentSessionsFolderIfExists(for: workspace) else { return [] }
        if let index = await readMetadataIndexIfAvailable(folder: folder) {
            scheduleMetadataIndexReconciliationIfNeeded(
                folder: folder,
                delaySeconds: Self.sidebarStreamMetadataIndexReconciliationDelaySeconds,
                reason: "sidebarStreamHotIndex",
                workspaceID: workspace.id
            )
            return try excludingTombstoned(index.entries.sortedForAgentSessionMetadataIndex())
        }
        let index = try await rebuildMetadataIndex(folder: folder)
        return try excludingTombstoned(index.entries.sortedForAgentSessionMetadataIndex())
    }

    /// One stable identity for a session file across URL spellings. Every lifecycle, reset,
    /// schedule-authority and deletion cache, and every pinned stamp, is keyed by it, so two
    /// workspace storage references that alias one directory (`/var` vs `/private/var`, a
    /// symlinked custom storage path) share one authoritative entry: a reset or deletion through
    /// one spelling fences a stale save through the other instead of hitting a stale cache entry.
    /// The existing parent directory is resolved with `realpath(3)`; when it cannot be resolved
    /// (absent folder) the standardized URL is used unchanged.
    private func canonicalSessionFileKey(_ fileURL: URL) -> URL {
        let standardized = fileURL.standardizedFileURL
        guard let directory = resolvedExistingDirectoryKey(standardized.deletingLastPathComponent()) else {
            return standardized
        }
        return directory.appendingPathComponent(standardized.lastPathComponent, isDirectory: false)
    }

    // MARK: - Tombstones

    private func tombstoneFileURL(for sessionID: UUID) -> URL {
        tombstoneRoot.appendingPathComponent("\(sessionID.uuidString).json")
    }

    /// Authoritative durable deletion state for one UUID. A read error other than absence throws:
    /// it is never treated as "not deleted".
    private func tombstoneState(for sessionID: UUID) throws -> AgentSessionTombstoneState {
        if knownTombstonedSessionIDs.contains(sessionID) {
            return Self.isTombstoneReadable(at: tombstoneFileURL(for: sessionID), sessionID: sessionID)
                ? .committed
                : .unreadable
        }
        let url = tombstoneFileURL(for: sessionID)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .absent
        }
        knownTombstonedSessionIDs.insert(sessionID)
        return Self.tombstone(data, matches: sessionID) ? .committed : .unreadable
    }

    private static func isTombstoneReadable(at url: URL, sessionID: UUID) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return tombstone(data, matches: sessionID)
    }

    private static func tombstone(_ data: Data, matches sessionID: UUID) -> Bool {
        guard let jsonValue = try? JSONDecoder().decode(AgentScheduledSendJSONValue.self, from: data),
              let tombstone = try? JSONDecoder().decode(AgentSessionDeletionTombstone.self, from: data),
              tombstone.schemaVersion == AgentSessionDeletionTombstone.currentSchemaVersion,
              tombstone.sessionID == sessionID,
              let typedData = try? JSONEncoder().encode(tombstone),
              let typedJSON = try? JSONDecoder().decode(AgentScheduledSendJSONValue.self, from: typedData),
              typedJSON == jsonValue
        else { return false }
        return true
    }

    /// Fails unless no tombstone (committed or unreadable) exists for `sessionID`.
    private func requireNoTombstone(for sessionID: UUID) throws {
        switch try tombstoneState(for: sessionID) {
        case .absent:
            return
        case .committed:
            throw AgentScheduledSendMutationError.sessionDeleted(sessionID)
        case .unreadable:
            throw AgentScheduledSendMutationError.unreadableTombstone(sessionID)
        }
    }

    /// Optional lookups (editable load, hydration): a committed tombstone reads like an absent
    /// file (`true`, no authority is issued), an unreadable one fails closed. Creation and saves
    /// remain fenced by `requireNoTombstone`.
    private func isCommittedTombstone(for sessionID: UUID) throws -> Bool {
        switch try tombstoneState(for: sessionID) {
        case .absent:
            return false
        case .committed:
            return true
        case .unreadable:
            throw AgentScheduledSendMutationError.unreadableTombstone(sessionID)
        }
    }

    /// Whether `sessionID` is durably deleted. Lets a hydration that found no payload tell a
    /// deleted binding (restored after a crash between the tombstone and the workspace unbind)
    /// from a genuine creator. An unreadable tombstone throws (fail closed).
    package func isAgentSessionDeleted(id sessionID: UUID) throws -> Bool {
        try isCommittedTombstone(for: sessionID)
    }

    /// Every tombstoned UUID (committed or unreadable) for listing filters. A directory read
    /// failure other than absence throws rather than resurrecting deleted sessions.
    private func tombstonedSessionIDs() throws -> Set<UUID> {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: tombstoneRoot,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return knownTombstonedSessionIDs
        }
        for url in contents where url.pathExtension == "json" {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) {
                knownTombstonedSessionIDs.insert(id)
            }
        }
        return knownTombstonedSessionIDs
    }

    /// `true` when an on-disk session file belongs to a tombstoned UUID. The first time this
    /// service hides residue for a UUID it logs the file and its tombstone. A tombstone is the
    /// permanent, UUID-wide retirement record: removing it would re-enable stale owners of that
    /// incarnation, so recovering residue content (for example, a restored backup) requires a
    /// deliberate offline repair under a new session identity, never deleting the tombstone.
    private func isTombstonedResidue(_ fileURL: URL, sessionID: UUID, tombstoned: Set<UUID>) -> Bool {
        guard tombstoned.contains(sessionID) else { return false }
        if loggedTombstonedResidueSessionIDs.insert(sessionID).inserted {
            print("[AgentSessionDataService] hiding session file \(fileURL.path): session \(sessionID) is retired by tombstone \(tombstoneFileURL(for: sessionID).path); recovering it requires a deliberate repair under a new session identity")
        }
        return true
    }

    private func excludingTombstoned(_ records: [AgentSessionMetadataRecord]) throws -> [AgentSessionMetadataRecord] {
        guard !records.isEmpty else { return records }
        let tombstoned = try tombstonedSessionIDs()
        guard !tombstoned.isEmpty else { return records }
        return records.filter { !tombstoned.contains($0.id) }
    }

    /// Commit point of a deletion: atomically writes the tombstone if absent. Never replaces an
    /// existing (including unreadable) tombstone. Returns `true` only when this call committed it.
    private func commitTombstone(for sessionID: UUID) throws -> Bool {
        switch try tombstoneState(for: sessionID) {
        case .committed:
            return false
        case .unreadable:
            throw AgentScheduledSendMutationError.unreadableTombstone(sessionID)
        case .absent:
            break
        }
        #if DEBUG
            if let injected = test_tombstoneWriteFailureInjector?(sessionID) {
                throw injected
            }
        #endif
        try FileManager.default.createDirectory(at: tombstoneRoot, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(AgentSessionDeletionTombstone(sessionID: sessionID))
        try data.write(to: tombstoneFileURL(for: sessionID), options: .atomic)
        knownTombstonedSessionIDs.insert(sessionID)
        return true
    }

    // MARK: - Lifecycle authority

    private enum DurableLifecycleState {
        /// A supported legacy envelope without a lifecycle member (not yet migrated).
        case legacy
        case v1(AgentSessionLifecycle)
    }

    /// Envelope and lifecycle checks applied to a decoded session before normalization or any
    /// rewrite. Unsupported envelopes and unreadable lifecycle never reach a writer.
    private static func validateDecodedEnvelope(_ session: AgentSession) throws -> DurableLifecycleState {
        try validateEnvelope(sessionID: session.id, serializationVersion: session.serializationVersion, lifecycle: session.lifecycle)
    }

    private static func validateEnvelope(
        sessionID: UUID,
        serializationVersion: Int,
        lifecycle: AgentSessionLifecycleMember?
    ) throws -> DurableLifecycleState {
        guard AgentSession.supportedSerializationVersions.contains(serializationVersion) else {
            throw AgentScheduledSendMutationError.unsupportedSessionEnvelope(
                sessionID,
                serializationVersion: serializationVersion
            )
        }
        switch lifecycle {
        case nil:
            return .legacy
        case let .v1(value):
            return .v1(value)
        case .unreadable:
            throw AgentScheduledSendMutationError.unreadableLifecycle(sessionID)
        }
    }

    /// Current durable state of an existing file, from this service's cache or an envelope read.
    /// Callers hold the gate and have verified the file exists.
    private func currentDurableLifecycle(fileURL: URL, sessionID: UUID) throws -> DurableLifecycleState {
        let key = canonicalSessionFileKey(fileURL)
        if let cached = lifecycleByFileKey[key] {
            return .v1(cached)
        }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let header = try AgentSessionDataCodec.decodeEnvelope(
            AgentSessionLifecycleHeader.self,
            from: data,
            using: decoder
        ).value
        let state = try Self.validateEnvelope(
            sessionID: sessionID,
            serializationVersion: header.serializationVersion,
            lifecycle: header.lifecycle
        )
        if case let .v1(value) = state {
            lifecycleByFileKey[key] = value
        }
        return state
    }

    private func rememberLifecycle(of session: AgentSession, fileURL: URL) {
        let key = canonicalSessionFileKey(fileURL)
        if let lifecycle = session.lifecycle?.lifecycle {
            lifecycleByFileKey[key] = lifecycle
        } else {
            lifecycleByFileKey.removeValue(forKey: key)
        }
    }

    private func persistenceState(
        sessionID: UUID,
        workspaceID: UUID,
        fileURL: URL,
        lifecycle: AgentSessionLifecycle
    ) -> AgentSessionPersistenceState {
        let fileKey = canonicalSessionFileKey(fileURL)
        return AgentSessionPersistenceState(
            stamp: AgentSessionPersistenceStamp(
                sessionID: sessionID,
                workspaceID: workspaceID,
                deletionGeneration: deletionGenerationsByFileKey[fileKey] ?? 0,
                incarnationID: lifecycle.incarnationID,
                serviceID: persistenceServiceID,
                fileURL: fileKey
            ),
            transcriptResetGeneration: lifecycle.transcriptResetGeneration
        )
    }

    /// Editable authority for a gate-held loaded (and therefore migrated) runtime session.
    private func editablePersistenceState(
        for session: AgentSession,
        workspaceID: UUID,
        fileURL: URL
    ) throws -> AgentSessionPersistenceState {
        guard let lifecycle = session.lifecycle?.lifecycle else {
            throw AgentScheduledSendMutationError.unreadableLifecycle(session.id)
        }
        return persistenceState(
            sessionID: session.id,
            workspaceID: workspaceID,
            fileURL: fileURL,
            lifecycle: lifecycle
        )
    }

    private func validatePersistenceStamp(
        _ stamp: AgentSessionPersistenceStamp,
        sessionID: UUID,
        workspaceID: UUID
    ) throws {
        guard stamp.serviceID == persistenceServiceID,
              stamp.sessionID == sessionID,
              stamp.workspaceID == workspaceID
        else {
            throw AgentScheduledSendMutationError.invalidPersistenceStamp
        }
        let currentGeneration = deletionGenerationsByFileKey[stamp.fileURL] ?? 0
        guard stamp.deletionGeneration == currentGeneration else {
            throw AgentScheduledSendMutationError.staleDeletionGeneration(
                expected: stamp.deletionGeneration,
                actual: currentGeneration
            )
        }
    }

    /// The loaded (migrated) session must still be the stamp's durable incarnation.
    private func validateStampIncarnation(
        _ stamp: AgentSessionPersistenceStamp,
        against session: AgentSession
    ) throws {
        let actual = session.lifecycle?.lifecycle?.incarnationID
        guard let expected = stamp.incarnationID, expected == actual else {
            throw AgentScheduledSendMutationError.staleIncarnation(expected: stamp.incarnationID, actual: actual)
        }
    }

    private func sessionContainsItem(_ session: AgentSession, itemID: UUID) -> Bool {
        if session.items.contains(where: { $0.id == itemID }) {
            return true
        }
        guard let transcript = session.transcript else { return false }
        for turn in transcript.turns {
            if turn.request?.id == itemID {
                return true
            }
            if turn.responseSpans.contains(where: {
                $0.activities.contains(where: { $0.id == itemID })
            }) {
                return true
            }
        }
        return false
    }

    private func scheduleAuthority(
        _ authority: AgentSessionScheduleAuthority,
        applyingTranscriptResetTo postResetSession: AgentSession
    ) -> AgentSessionScheduleAuthority {
        var updated = authority
        for (itemID, protectedItem) in authority.protectedAcceptedUserItemsByID
            where !sessionContainsItem(postResetSession, itemID: itemID)
        {
            guard let receipt = protectedItem.scheduledSend else { continue }
            updated.protectedAcceptedUserItemsByID.removeValue(forKey: itemID)
            updated.intentionallyRemovedAcceptedUserItemReceiptsByID[itemID] = receipt
        }
        return updated
    }

    private func cachedOrLoadedScheduleAuthority(
        for fileURL: URL
    ) throws -> AgentSessionScheduleAuthority {
        let key = canonicalSessionFileKey(fileURL)
        if let cached = scheduleAuthorityByFileURL[key] {
            return cached
        }

        let persistedData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let persistedHeader = try AgentSessionDataCodec.decodeEnvelope(
            AgentSessionScheduleHeader.self,
            from: persistedData,
            using: decoder
        ).value
        let authority = AgentSessionScheduleAuthority(
            scheduledSend: persistedHeader.scheduledSend,
            lastScheduledDispatch: persistedHeader.lastScheduledDispatch,
            protectedAcceptedUserItemsByID: [:],
            intentionallyRemovedAcceptedUserItemReceiptsByID: [:]
        )
        scheduleAuthorityByFileURL[key] = authority
        return authority
    }

    private func rememberScheduleAuthority(
        from session: AgentSession,
        fileURL: URL,
        protecting acceptedUserItem: AgentChatItem? = nil,
        preservingItemAuthority itemAuthority: AgentSessionScheduleAuthority? = nil
    ) {
        let key = canonicalSessionFileKey(fileURL)
        let existingAuthority = itemAuthority ?? scheduleAuthorityByFileURL[key]
        var protectedItems = existingAuthority?.protectedAcceptedUserItemsByID ?? [:]
        var intentionallyRemovedItems =
            existingAuthority?.intentionallyRemovedAcceptedUserItemReceiptsByID ?? [:]
        if let acceptedUserItem {
            protectedItems[acceptedUserItem.id] = acceptedUserItem
            intentionallyRemovedItems.removeValue(forKey: acceptedUserItem.id)
        }
        scheduleAuthorityByFileURL[key] = AgentSessionScheduleAuthority(
            scheduledSend: session.scheduledSend,
            lastScheduledDispatch: session.lastScheduledDispatch,
            protectedAcceptedUserItemsByID: protectedItems,
            intentionallyRemovedAcceptedUserItemReceiptsByID: intentionallyRemovedItems
        )
    }

    private func scheduleAuthority(
        _ authority: AgentSessionScheduleAuthority,
        applying removals: [AgentScheduledSendFinalizedItemRemoval],
        to session: AgentSession,
        staleRemovalPolicy: StaleFinalizedItemRemovalPolicy = .fail
    ) throws -> AgentSessionScheduleAuthority {
        guard !removals.isEmpty else { return authority }

        var updated = authority
        for removal in removals {
            let conflictingReceipt = [
                updated.protectedAcceptedUserItemsByID[removal.itemID]?.scheduledSend,
                scheduledSendProvenance(in: session, itemID: removal.itemID),
                updated.intentionallyRemovedAcceptedUserItemReceiptsByID[removal.itemID]
            ]
            .compactMap(\.self)
            .first { $0 != removal.receipt }

            if let conflictingReceipt {
                switch staleRemovalPolicy {
                case .fail:
                    throw AgentScheduledSendMutationError.staleExpectedFinalizedItem(
                        itemID: removal.itemID,
                        expected: removal.receipt,
                        actual: conflictingReceipt
                    )
                case .ignore:
                    // The explicit reset still commits, but must not erase a newer accepted item.
                    continue
                }
            }
            updated.protectedAcceptedUserItemsByID.removeValue(forKey: removal.itemID)
            updated.intentionallyRemovedAcceptedUserItemReceiptsByID[removal.itemID] = removal.receipt
        }
        return updated
    }

    private func sessionByApplyingScheduleAuthority(
        _ authority: AgentSessionScheduleAuthority,
        to session: AgentSession
    ) -> AgentSession {
        var merged = session
        merged.scheduledSend = authority.scheduledSend
        merged.lastScheduledDispatch = authority.lastScheduledDispatch
        merged = sessionByMergingProtectedAcceptedUserItems(
            authority.protectedAcceptedUserItemsByID,
            into: merged
        )
        return sessionByRemovingIntentionallyRemovedAcceptedUserItems(
            authority.intentionallyRemovedAcceptedUserItemReceiptsByID,
            from: merged
        )
    }

    private func scheduledSendProvenance(
        in session: AgentSession,
        itemID: UUID
    ) -> AgentScheduledSendProvenance? {
        if let item = session.items.first(where: { $0.id == itemID }),
           let receipt = item.scheduledSend
        {
            return receipt
        }
        guard let transcript = session.transcript else { return nil }
        for turn in transcript.turns {
            if let request = turn.request,
               request.id == itemID,
               let receipt = request.scheduledSend
            {
                return receipt
            }
            for span in turn.responseSpans {
                if let receipt = span.activities.first(where: { $0.id == itemID })?.scheduledSend {
                    return receipt
                }
            }
        }
        return nil
    }

    private func finalizedScheduledUserItem(
        in session: AgentSession,
        itemID: UUID,
        receipt: AgentScheduledSendProvenance
    ) -> AgentChatItem? {
        if let item = session.items.first(where: {
            $0.id == itemID && $0.scheduledSend == receipt
        }) {
            return item.toItem()
        }
        guard let transcript = session.transcript else { return nil }
        for turn in transcript.turns {
            if let request = turn.request,
               request.id == itemID,
               request.scheduledSend == receipt
            {
                return request.toItem()
            }
            for span in turn.responseSpans {
                if let activity = span.activities.first(where: {
                    $0.id == itemID && $0.scheduledSend == receipt
                }) {
                    return activity.toItem()
                }
            }
        }
        return nil
    }

    private func sessionByRemovingIntentionallyRemovedAcceptedUserItems(
        _ removedItemReceiptsByID: [UUID: AgentScheduledSendProvenance],
        from session: AgentSession
    ) -> AgentSession {
        guard !removedItemReceiptsByID.isEmpty else { return session }

        var updated = session
        updated.items.removeAll { removedItemReceiptsByID[$0.id] != nil }
        if var transcript = updated.transcript {
            for turnIndex in transcript.turns.indices {
                if let request = transcript.turns[turnIndex].request,
                   removedItemReceiptsByID[request.id] != nil
                {
                    transcript.turns[turnIndex].request = nil
                }
                for spanIndex in transcript.turns[turnIndex].responseSpans.indices {
                    transcript.turns[turnIndex].responseSpans[spanIndex].activities.removeAll {
                        removedItemReceiptsByID[$0.id] != nil
                    }
                }
            }
            updated.transcript = transcript
        }
        return updated
    }

    private func sessionByMergingProtectedAcceptedUserItems(
        _ protectedItemsByID: [UUID: AgentChatItem],
        into session: AgentSession
    ) -> AgentSession {
        guard !protectedItemsByID.isEmpty else { return session }

        var merged = session
        var workingItems = merged.workingSourceItems()
        var didChange = false
        let protectedItems = protectedItemsByID.values.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }

        for protectedItem in protectedItems {
            if let receipt = protectedItem.scheduledSend,
               finalizedScheduledUserItem(
                   in: merged,
                   itemID: protectedItem.id,
                   receipt: receipt
               ) != nil
            {
                continue
            }
            if let existingIndex = workingItems.firstIndex(where: { $0.id == protectedItem.id }) {
                guard workingItems[existingIndex] != protectedItem else { continue }
                workingItems[existingIndex] = protectedItem
            } else {
                workingItems.append(protectedItem)
            }
            didChange = true
        }
        guard didChange else { return merged }

        workingItems.sort { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        let nextSequenceIndex = max(
            merged.transcript?.nextSequenceIndex ?? 0,
            (workingItems.map(\.sequenceIndex).max() ?? -1) + 1
        )
        let terminalState = merged.lastRunState.flatMap(AgentSessionRunState.init(rawValue:))
        if let transcript = merged.transcript {
            merged.transcript = AgentTranscriptIO.rebuiltTranscriptPreservingCompactedPrefix(
                existingTranscript: transcript,
                workingItems: workingItems,
                terminalState: terminalState,
                nextSequenceIndex: nextSequenceIndex,
                policy: .canonical
            )
        } else {
            merged.transcript = AgentTranscriptIO.buildTranscript(
                from: workingItems,
                terminalState: terminalState,
                nextSequenceIndex: nextSequenceIndex,
                policy: .canonical
            )
        }
        merged.items = workingItems.map {
            AgentChatItemPersist(from: $0, sanitizeToolResults: false)
        }
        return merged
    }

    // MARK: - Public API

    /// Durable exclusive initial creation. Under the session gate it rejects a tombstone or an
    /// existing file, assigns fresh lifecycle (reset generation zero), and writes the normal
    /// session file with the existing atomic writer; the caller adopts the committed session and
    /// state together. Exclusivity is the gate's: DataService is the app's sole session writer, so
    /// two creators of one UUID through it serialize, one commits, and the other receives
    /// `sessionAlreadyExists` (never adopts the winner). Independent service instances or
    /// processes on one storage directory are outside this contract. Later saves by the owner
    /// require the existing file.
    package func prepareInitialAgentSessionPersistence(
        initialSession: AgentSession,
        for workspace: some AgentWorkspaceStorageReference,
        preparation: SavePreparation = .canonicalize,
        trustedCanonicalItemCount: Int? = nil
    ) async throws -> AgentSessionEditableLoad {
        let sessionID = initialSession.id
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        guard initialSession.lifecycle == nil,
              initialSession.workspaceID == nil || initialSession.workspaceID == workspace.id,
              !(initialSession.isListStub && initialSession.effectiveItemCount > 0)
        else {
            throw AgentScheduledSendMutationError.invalidInitialSession(sessionID)
        }
        let folder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionFileURL(id: sessionID, in: folder)
        try requireNoTombstone(for: sessionID)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionAlreadyExists(sessionID)
        }
        let commit = try await saveAgentSessionLocked(
            initialSession,
            for: workspace,
            preparation: preparation,
            trustedCanonicalItemCount: trustedCanonicalItemCount,
            intentionallyRemovingFinalizedScheduledSendItems: [],
            committingTranscriptReset: nil,
            fileCreationPolicy: .createIfMissing,
            authority: .compatibility,
            countsAsFullSave: false
        )
        guard let committedSession = commit.committedSession else {
            throw AgentScheduledSendMutationError.sessionAlreadyExists(sessionID)
        }
        return AgentSessionEditableLoad(session: committedSession, persistenceState: commit.persistenceState)
    }

    /// Loads an editable session and its process-local persistence state under one gate. The
    /// caller must adopt both values together; the state cannot safely authorize an older snapshot.
    /// Cold hydration uses `loadAgentSessionForHydration`, except in the DEBUG sequential
    /// reference mode (`forcesSequentialHydrationPreparation`), which keeps this path.
    func loadAgentSessionForEditing(
        id sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference
    ) async throws -> AgentSessionEditableLoad? {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        let folder = agentSessionsFolderURL(for: workspace)
        let fileURL = agentSessionFileURL(id: sessionID, in: folder)
        guard try !isCommittedTombstone(for: sessionID),
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return nil }
        // The sequential hydration reference: a cold restoration.
        let session = try await loadAgentSessionLocked(from: fileURL, purpose: .coldRestore)
        return try AgentSessionEditableLoad(
            session: session,
            persistenceState: editablePersistenceState(
                for: session,
                workspaceID: workspace.id,
                fileURL: fileURL
            )
        )
    }

    /// Cold hydration's counterpart of `loadAgentSessionForEditing`: one gate-held operation that
    /// loads the session exactly as `loadAgentSessionLocked` does while overlapping the load's
    /// storage canonicalization with the hydration branch.
    ///
    /// Order: read, decode, and runtime normalization (off the actor); worktree merge
    /// reconciliation; then two branches on the reconciled runtime session. The storage branch
    /// prepares the stored form and the rewrite decision and encodes off the actor, then writes,
    /// updates the metadata index, and records schedule authority on the actor. The hydration
    /// branch is a structured child task (`async let`), so task-locals and cancellation propagate.
    /// The storage branch does not observe cancellation and always completes before the hydration
    /// branch is joined; the persistence state is captured after it and the gate is released, as in the
    /// sequential path; then the hydration branch is awaited and cancellation is checked once more.
    /// A storage failure releases the gate, then throws `loadFailed`; leaving the scope cancels and
    /// implicitly awaits the hydration branch, whose result is discarded. A hydration failure,
    /// including cancellation, is rethrown after the storage branch completed and the gate was released.
    /// The gate is never held while only the hydration branch runs: that branch reads only its value
    /// inputs.
    func loadAgentSessionForHydration(
        id sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        inputs: AgentSessionHydrationBranchInputs
    ) async throws -> AgentSessionHydrationLoad? {
        await acquireSessionPersistence(for: sessionID)
        var holdsSessionPersistence = true
        defer {
            if holdsSessionPersistence {
                releaseSessionPersistence(for: sessionID)
            }
        }
        let folder = agentSessionsFolderURL(for: workspace)
        let fileURL = agentSessionFileURL(id: sessionID, in: folder)
        guard try !isCommittedTombstone(for: sessionID),
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return nil }

        let prefix: HydrationLoadPrefix
        let interruptionContext = await coldRestoreInterruptionContext(sessionID: sessionID)
        do {
            prefix = try await Self.hydrationLoadPrefix(fileURL: fileURL, interruptionContext: interruptionContext)
        } catch {
            throw AgentSessionDataError.loadFailed(error)
        }
        // Lifecycle is decided on the actor before branching; a migration identity is returned
        // only after the storage branch durably committed it.
        var reconciledSession = prefix.runtimeSession
        if case .legacy = try Self.validateDecodedEnvelope(prefix.loadedSession) {
            reconciledSession.lifecycle = .v1(.fresh())
        }
        let reconciledMergeOperations = await AgentSessionWorktreeMergeReconciler.reconcile(reconciledSession.worktreeMergeOperations)
        let mergeOperationsChanged = reconciledMergeOperations != reconciledSession.worktreeMergeOperations
        if mergeOperationsChanged {
            reconciledSession.worktreeMergeOperations = reconciledMergeOperations
        }
        let runtimeSession = reconciledSession

        async let hydration = Self.hydrationBranchResultOffActor(for: runtimeSession, inputs: inputs)
        do {
            let rewrite = try await Self.hydrationStorageRewrite(
                loadedSession: prefix.loadedSession,
                runtimeSession: runtimeSession,
                fileURL: fileURL,
                mergeOperationsChanged: mergeOperationsChanged
            )
            #if DEBUG
                await Self.hydrationOverlapProbe?.storageCommitPoint()
            #endif
            try await commitLoadedSessionStorage(rewrite: rewrite, runtimeSession: runtimeSession, fileURL: fileURL)
            noteColdRestoreStamps(
                sessionID: sessionID,
                context: interruptionContext,
                transcript: runtimeSession.transcript
            )
            #if DEBUG
                Self.hydrationOverlapProbe?.branchFinished(.storage)
            #endif
        } catch {
            // Release the gate first: leaving scope then cancels and implicitly awaits the hydration
            // child (which reads only its value inputs), and its presentation is discarded.
            holdsSessionPersistence = false
            releaseSessionPersistence(for: sessionID)
            throw AgentSessionDataError.loadFailed(error)
        }
        let persistenceState: AgentSessionPersistenceState
        do {
            persistenceState = try editablePersistenceState(
                for: runtimeSession,
                workspaceID: workspace.id,
                fileURL: fileURL
            )
        } catch {
            holdsSessionPersistence = false
            releaseSessionPersistence(for: sessionID)
            throw error
        }
        // The hydration branch reads only its value inputs, so the gate scope ends here as in the
        // sequential path (which derives hydration after `loadAgentSessionForEditing` returns).
        holdsSessionPersistence = false
        releaseSessionPersistence(for: sessionID)
        let hydrationResult = try await hydration
        // An already-finished child does not observe a cancellation that arrived during storage.
        try Task.checkCancellation()
        return AgentSessionHydrationLoad(
            editableLoad: AgentSessionEditableLoad(session: runtimeSession, persistenceState: persistenceState),
            hydration: hydrationResult
        )
    }

    /// The storage commit both load paths share: write a rewritten session and then index it, or
    /// refresh an existing index record; then record schedule authority.
    private func commitLoadedSessionStorage(
        rewrite: LoadedSessionStorageRewrite?,
        runtimeSession: AgentSession,
        fileURL: URL
    ) async throws {
        if let rewrite {
            try await writeDataAtomically(rewrite.encoded, to: fileURL)
            await upsertMetadataRecord(
                metadataRecord(from: rewrite.persistedSession, fileURL: fileURL),
                folder: fileURL.deletingLastPathComponent()
            )
        } else {
            await upsertMetadataRecordIfIndexPresent(runtimeSession, fileURL: fileURL)
        }
        rememberScheduleAuthority(from: runtimeSession, fileURL: fileURL)
        rememberLifecycle(of: runtimeSession, fileURL: fileURL)
    }

    /// Session file coders. The actor's coders and the fresh ones cold hydration uses off the actor
    /// come from these factories, so both paths encode and decode identically.
    private static func makeSessionEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    private static func makeSessionDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private struct HydrationLoadPrefix {
        /// The session as decoded from disk, compared against its stored form for the rewrite decision.
        let loadedSession: AgentSession
        /// The runtime normalization of `loadedSession`, before merge reconciliation.
        let runtimeSession: AgentSession
    }

    private struct LoadedSessionStorageRewrite {
        let persistedSession: AgentSession
        let encoded: Data
    }

    /// Off-actor prefix of the hydration load: read, decode, and runtime normalization, as in
    /// `loadAgentSessionLocked`. Decoding uses a fresh decoder from `makeSessionDecoder`.
    @concurrent
    private static func hydrationLoadPrefix(
        fileURL: URL,
        interruptionContext: AgentColdRestoreInterruptionContext?
    ) async throws -> HydrationLoadPrefix {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let loadedSession = try AgentSessionDataCodec.decodeSession(from: data, using: makeSessionDecoder())
        return HydrationLoadPrefix(
            loadedSession: loadedSession,
            runtimeSession: runtimeNormalizedLoadedSession(
                loadedSession,
                fileURL: fileURL,
                purpose: .coldRestore,
                interruptionContext: interruptionContext?.withProviderConversationID(loadedSession.providerSessionID)
            )
        )
    }

    /// Off-actor pure part of the hydration storage branch: the stored form of the reconciled runtime
    /// session and `loadAgentSessionLocked`'s rewrite decision (normalization differences, or changed
    /// merge operations, keeping the decoded `savedAt`), encoded with a fresh encoder from
    /// `makeSessionEncoder`. Returns nil when no rewrite is needed.
    @concurrent
    private static func hydrationStorageRewrite(
        loadedSession: AgentSession,
        runtimeSession: AgentSession,
        fileURL: URL,
        mergeOperationsChanged: Bool
    ) async throws -> LoadedSessionStorageRewrite? {
        #if DEBUG
            await hydrationOverlapProbe?.branchStarted(.storage)
        #endif
        let storage = storageNormalizedLoadedSession(loadedSession, runtimeSession: runtimeSession, fileURL: fileURL)
        guard storage.needsRewrite || mergeOperationsChanged else { return nil }
        return try LoadedSessionStorageRewrite(
            persistedSession: storage.persistedSession,
            encoded: AgentSessionDataCodec.encodeSession(storage.persistedSession, using: makeSessionEncoder())
        )
    }

    /// Saves the full session while keeping schedule persistence under its dedicated CAS authority.
    ///
    /// On initial creation, the supplied schedule fields are written as-is. Once the file exists,
    /// its `scheduledSend` and `lastScheduledDispatch` members are authoritative and are merged
    /// into the full-session payload. Callers use `mutateScheduledSend` for schedule changes and
    /// `finalizeScheduledSend` for provider-accepted turns. Finalized user items remain protected
    /// from stale VM snapshots until a caller explicitly supplies their exact item/receipt identities
    /// in `intentionallyRemovingFinalizedScheduledSendItems`. Explicit removals install process-local
    /// tombstones so later stale snapshots cannot resurrect the removed items. A committed transcript
    /// reset also records its canonical post-reset snapshot for accepted-send recovery after accidental
    /// file loss. This URL-returning overload remains for generic compatibility; editable Agent Mode
    /// owners must use the persistence-state overload below.
    ///
    /// Compatibility lifecycle rules (the creation policy never overrides them):
    /// - existing file: `session` must carry the typed lifecycle it was loaded with, matching the
    ///   current incarnation and reset generation (load-modify-save), otherwise the save fails;
    /// - missing file: only a genuinely new, lifecycle-absent session with no tombstone is created,
    ///   exclusively; a lifecycle-bearing snapshot is never reconstructed (`sessionNotFound`);
    /// - transcript resets are rejected; they commit only through the persistence-state overload.
    package func saveAgentSession(
        _ session: AgentSession,
        for workspace: some AgentWorkspaceStorageReference,
        preparation: SavePreparation = .canonicalize,
        trustedCanonicalItemCount: Int? = nil,
        intentionallyRemovingFinalizedScheduledSendItems removals: [AgentScheduledSendFinalizedItemRemoval] = [],
        committingTranscriptReset resetReceipt: AgentSessionTranscriptResetReceipt? = nil,
        fileCreationPolicy: AgentSessionFileCreationPolicy = .createIfMissing
    ) async throws -> URL {
        await acquireSessionPersistence(for: session.id)
        defer { releaseSessionPersistence(for: session.id) }
        let commit = try await saveAgentSessionLocked(
            session,
            for: workspace,
            preparation: preparation,
            trustedCanonicalItemCount: trustedCanonicalItemCount,
            intentionallyRemovingFinalizedScheduledSendItems: removals,
            committingTranscriptReset: resetReceipt,
            fileCreationPolicy: fileCreationPolicy,
            authority: .compatibility
        )
        return commit.fileURL
    }

    /// Fenced full-save entry point for an editable owner. The returned state is the only state
    /// that owner may use for later saves; failures never refresh or transfer ownership. The file
    /// must exist (initial creation is `prepareInitialAgentSessionPersistence`), regardless of
    /// `fileCreationPolicy`. DataService merges the durable lifecycle into the payload; the
    /// payload's own `lifecycle` member is never trusted.
    ///
    /// Reset commit: a receipt equal to the persisted latest receipt is acknowledged without a
    /// write (`.resetAlreadyCommitted`) when the state's generation is current or its immediate
    /// predecessor; otherwise the generation must be current, and the reset transcript, the
    /// incremented generation, and the receipt are written in one replacement.
    package func saveAgentSession(
        _ session: AgentSession,
        for workspace: some AgentWorkspaceStorageReference,
        preparation: SavePreparation = .canonicalize,
        trustedCanonicalItemCount: Int? = nil,
        intentionallyRemovingFinalizedScheduledSendItems removals: [AgentScheduledSendFinalizedItemRemoval] = [],
        committingTranscriptReset resetReceipt: AgentSessionTranscriptResetReceipt? = nil,
        fileCreationPolicy: AgentSessionFileCreationPolicy = .createIfMissing,
        persistenceState: AgentSessionPersistenceState,
        committingHistoryImport historyImport: AgentSessionProviderHistoryRecovery.ImportCommit? = nil
    ) async throws -> AgentSessionSaveCommit {
        if let historyImport, session.providerHistoryRecovery?.lastImportCommit != historyImport {
            throw AgentSessionHistoryImportError.receiptMismatch
        }
        await acquireSessionPersistence(for: session.id)
        defer { releaseSessionPersistence(for: session.id) }
        return try await saveAgentSessionLocked(
            session,
            for: workspace,
            preparation: preparation,
            trustedCanonicalItemCount: trustedCanonicalItemCount,
            intentionallyRemovingFinalizedScheduledSendItems: removals,
            committingTranscriptReset: resetReceipt,
            fileCreationPolicy: fileCreationPolicy,
            authority: .persistenceState(persistenceState),
            committingHistoryImport: historyImport?.importID
        )
    }

    /// Provider-history import commit (lossless restart Phase 4): the session rows, the native-ID
    /// ledger, and `importCommit` are written in ONE fenced full save; the caller advances the
    /// recovery cursor only after this returns. The payload must already carry exactly
    /// `importCommit` as its latest import receipt. From then on, an ordinary save whose payload
    /// carries a different receipt under the same incarnation is refused as an older snapshot
    /// (`AgentSessionHistoryImportError.staleHistorySnapshot`), until a transcript reset clears it.
    package func commitProviderHistoryImport(
        _ session: AgentSession,
        for workspace: some AgentWorkspaceStorageReference,
        importCommit: AgentSessionProviderHistoryRecovery.ImportCommit,
        persistenceState: AgentSessionPersistenceState
    ) async throws -> AgentSessionSaveCommit {
        try await saveAgentSession(
            session,
            for: workspace,
            preparation: .canonicalize,
            fileCreationPolicy: .requireExisting,
            persistenceState: persistenceState,
            committingHistoryImport: importCommit
        )
    }

    /// The stale-import fence of every full save (see `committedHistoryImportByFileURL`).
    private func validateHistoryImportFence(
        _ session: AgentSession,
        fileKey: URL,
        incarnationID: UUID,
        committingTranscriptReset: Bool,
        committingHistoryImport historyImportID: UUID?
    ) throws {
        let payloadImportID = session.providerHistoryRecovery?.lastImportCommit?.importID
        if let historyImportID {
            guard payloadImportID == historyImportID, !committingTranscriptReset else {
                throw AgentSessionHistoryImportError.receiptMismatch
            }
            return
        }
        guard !committingTranscriptReset,
              let committed = committedHistoryImportByFileURL[fileKey],
              committed.incarnationID == incarnationID
        else { return }
        guard payloadImportID == committed.importID else {
            throw AgentSessionHistoryImportError.staleHistorySnapshot
        }
    }

    private enum SaveAuthority {
        /// Generic load-modify-save or genuine exclusive creation; authority is the payload's own
        /// loaded lifecycle.
        case compatibility
        /// Editable owner; authority is the captured service-issued state.
        case persistenceState(AgentSessionPersistenceState)
    }

    private func saveAgentSessionLocked(
        _ session: AgentSession,
        for workspace: some AgentWorkspaceStorageReference,
        preparation: SavePreparation,
        trustedCanonicalItemCount: Int?,
        intentionallyRemovingFinalizedScheduledSendItems removals: [AgentScheduledSendFinalizedItemRemoval],
        committingTranscriptReset resetReceipt: AgentSessionTranscriptResetReceipt?,
        fileCreationPolicy: AgentSessionFileCreationPolicy,
        authority: SaveAuthority,
        countsAsFullSave: Bool = true,
        committingHistoryImport historyImportID: UUID? = nil
    ) async throws -> AgentSessionSaveCommit {
        let agentSessionsFolder: URL
        let fileURL: URL
        if case let .persistenceState(expectedPersistenceState) = authority {
            try validatePersistenceStamp(
                expectedPersistenceState.stamp,
                sessionID: session.id,
                workspaceID: workspace.id
            )
            fileURL = expectedPersistenceState.stamp.fileURL
            agentSessionsFolder = fileURL.deletingLastPathComponent()
        } else {
            agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
            fileURL = agentSessionFileURL(id: session.id, in: agentSessionsFolder)
        }
        let fileKey = canonicalSessionFileKey(fileURL)
        try requireNoTombstone(for: session.id)

        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
        // `nil` only for a genuine exclusive creation.
        let currentLifecycle: AgentSessionLifecycle?
        switch authority {
        case let .persistenceState(expected):
            guard fileExists else {
                throw AgentScheduledSendMutationError.sessionNotFound(session.id)
            }
            guard case let .v1(current) = try currentDurableLifecycle(fileURL: fileURL, sessionID: session.id) else {
                throw AgentScheduledSendMutationError.staleIncarnation(expected: expected.stamp.incarnationID, actual: nil)
            }
            guard expected.stamp.incarnationID == current.incarnationID else {
                throw AgentScheduledSendMutationError.staleIncarnation(
                    expected: expected.stamp.incarnationID,
                    actual: current.incarnationID
                )
            }
            let isCurrentOrImmediatePredecessor =
                expected.transcriptResetGeneration <= current.transcriptResetGeneration
                    && current.transcriptResetGeneration - expected.transcriptResetGeneration <= 1
            if let resetReceipt,
               current.lastTranscriptResetReceipt == resetReceipt,
               isCurrentOrImmediatePredecessor
            {
                return AgentSessionSaveCommit(
                    fileURL: fileURL,
                    persistenceState: persistenceState(
                        sessionID: session.id,
                        workspaceID: workspace.id,
                        fileURL: fileURL,
                        lifecycle: current
                    ),
                    disposition: .resetAlreadyCommitted,
                    committedSession: nil
                )
            }
            guard expected.transcriptResetGeneration == current.transcriptResetGeneration else {
                throw AgentScheduledSendMutationError.staleTranscriptResetGeneration(
                    expected: expected.transcriptResetGeneration,
                    actual: current.transcriptResetGeneration
                )
            }
            currentLifecycle = current
        case .compatibility:
            guard resetReceipt == nil else {
                throw AgentScheduledSendMutationError.transcriptResetRequiresPersistenceState
            }
            if fileExists {
                let durable = try currentDurableLifecycle(fileURL: fileURL, sessionID: session.id)
                let supplied: AgentSessionLifecycle
                switch session.lifecycle {
                case nil:
                    throw AgentScheduledSendMutationError.missingLifecycle(session.id)
                case .unreadable:
                    throw AgentScheduledSendMutationError.unreadableLifecycle(session.id)
                case let .v1(value):
                    supplied = value
                }
                guard case let .v1(current) = durable else {
                    // A legacy file is migrated by a gate-held load before any authority exists.
                    throw AgentScheduledSendMutationError.staleIncarnation(expected: supplied.incarnationID, actual: nil)
                }
                guard supplied.incarnationID == current.incarnationID else {
                    throw AgentScheduledSendMutationError.staleIncarnation(
                        expected: supplied.incarnationID,
                        actual: current.incarnationID
                    )
                }
                guard supplied.transcriptResetGeneration == current.transcriptResetGeneration else {
                    throw AgentScheduledSendMutationError.staleTranscriptResetGeneration(
                        expected: supplied.transcriptResetGeneration,
                        actual: current.transcriptResetGeneration
                    )
                }
                currentLifecycle = current
            } else {
                guard case .createIfMissing = fileCreationPolicy, session.lifecycle == nil else {
                    // Never reconstruct a lifecycle-bearing snapshot as an ordinary save.
                    throw AgentScheduledSendMutationError.sessionNotFound(session.id)
                }
                currentLifecycle = nil
            }
        }
        let lifecycleToWrite: AgentSessionLifecycle
        if let currentLifecycle {
            if let resetReceipt {
                guard let advanced = currentLifecycle.advancingTranscriptReset(receipt: resetReceipt) else {
                    throw AgentScheduledSendMutationError.transcriptResetGenerationOverflow
                }
                lifecycleToWrite = advanced
            } else {
                lifecycleToWrite = currentLifecycle
            }
        } else {
            lifecycleToWrite = .fresh()
        }
        try validateHistoryImportFence(
            session,
            fileKey: fileKey,
            incarnationID: lifecycleToWrite.incarnationID,
            committingTranscriptReset: resetReceipt != nil,
            committingHistoryImport: historyImportID
        )

        let staleRemovalPolicy: StaleFinalizedItemRemovalPolicy =
            resetReceipt == nil ? .fail : .ignore
        var sessionWithAuthoritativeSchedule = session
        var itemAuthorityForSave: AgentSessionScheduleAuthority?
        if fileExists {
            var authority = try cachedOrLoadedScheduleAuthority(for: fileURL)
            authority = try scheduleAuthority(
                authority,
                applying: removals,
                to: session,
                staleRemovalPolicy: staleRemovalPolicy
            )
            if resetReceipt != nil {
                authority = scheduleAuthority(
                    authority,
                    applyingTranscriptResetTo: session
                )
            }
            itemAuthorityForSave = authority
            sessionWithAuthoritativeSchedule = sessionByApplyingScheduleAuthority(
                authority,
                to: sessionWithAuthoritativeSchedule
            )
        } else if !removals.isEmpty {
            var authority = AgentSessionScheduleAuthority(
                scheduledSend: session.scheduledSend,
                lastScheduledDispatch: session.lastScheduledDispatch,
                protectedAcceptedUserItemsByID: [:],
                intentionallyRemovedAcceptedUserItemReceiptsByID: [:]
            )
            authority = try scheduleAuthority(
                authority,
                applying: removals,
                to: session,
                staleRemovalPolicy: staleRemovalPolicy
            )
            itemAuthorityForSave = authority
            sessionWithAuthoritativeSchedule = sessionByApplyingScheduleAuthority(
                authority,
                to: sessionWithAuthoritativeSchedule
            )
        }
        let hasItemAuthority = itemAuthorityForSave.map {
            !$0.protectedAcceptedUserItemsByID.isEmpty
                || !$0.intentionallyRemovedAcceptedUserItemReceiptsByID.isEmpty
        } ?? false
        // Durable authority always comes from DataService, never from the payload.
        sessionWithAuthoritativeSchedule.lifecycle = .v1(lifecycleToWrite)

        #if DEBUG
            // Phase-boundary clocks are read only while diagnostics are enabled; later marks follow
            // the first so one save never reports a partial split.
            let diagnosticsPrepareStartMS = AgentModePerfDiagnostics.timestampMSIfEnabled()
        #endif
        let sessionToSave = Self.sessionPreparedForStorage(
            sessionWithAuthoritativeSchedule,
            fileURL: fileURL,
            savedAt: Date(),
            preparation: preparation,
            trustedCanonicalItemCount: resetReceipt != nil || hasItemAuthority
                ? nil
                : trustedCanonicalItemCount
        )
        #if DEBUG
            let diagnosticsEncodeStartMS = diagnosticsPrepareStartMS.map { _ in AgentModePerfDiagnostics.timestampMS() }
        #endif
        let freshEncoder = JSONEncoder()
        // Field-local codec: `providerUsage` bytes are re-inserted verbatim; any preservation
        // failure throws here, before the atomic writer replaces the file.
        let data = try AgentSessionDataCodec.encodeSession(sessionToSave, using: freshEncoder)
        #if DEBUG
            let diagnosticsWriteStartMS = diagnosticsEncodeStartMS.map { _ in AgentModePerfDiagnostics.timestampMS() }
        #endif
        // Creation is exclusive by the app contract, not by a filesystem primitive: DataService
        // (`.shared`) is the sole session writer and this gate is held from the absence check
        // above through the atomic write, so of two creators of one UUID exactly one writes and
        // the other observes the file (`sessionAlreadyExists`).
        try await writeDataAtomically(data, to: fileURL)
        #if DEBUG
            // The atomic replacement has returned successfully: this is the full-save commit point,
            // recorded before schedule/reset authority and metadata-index work. Owner creation via
            // `prepareInitialAgentSessionPersistence` is not a full save and is not counted.
            if countsAsFullSave {
                Self.recordFullSessionWrittenDiagnostics(
                    sessionToSave,
                    encodedByteCount: data.count,
                    committingTranscriptReset: resetReceipt != nil,
                    prepareStartMS: diagnosticsPrepareStartMS,
                    encodeStartMS: diagnosticsEncodeStartMS,
                    writeStartMS: diagnosticsWriteStartMS
                )
            }
        #endif
        rememberScheduleAuthority(
            from: sessionToSave,
            fileURL: fileURL,
            preservingItemAuthority: itemAuthorityForSave
        )
        rememberLifecycle(of: sessionToSave, fileURL: fileURL)
        if resetReceipt != nil {
            committedHistoryImportByFileURL[fileKey] = nil
        } else if let historyImportID {
            committedHistoryImportByFileURL[fileKey] = (lifecycleToWrite.incarnationID, historyImportID)
        }
        if let resetReceipt {
            transcriptResetAuthorityByFileURL[fileKey] =
                AgentSessionTranscriptResetAuthority(
                    incarnationID: lifecycleToWrite.incarnationID,
                    generation: lifecycleToWrite.transcriptResetGeneration,
                    receipt: resetReceipt,
                    canonicalSessionSnapshot: data
                )
        }
        await upsertMetadataRecord(metadataRecord(from: sessionToSave, fileURL: fileURL), folder: agentSessionsFolder)
        return AgentSessionSaveCommit(
            fileURL: fileURL,
            persistenceState: persistenceState(
                sessionID: session.id,
                workspaceID: workspace.id,
                fileURL: fileURL,
                lifecycle: lifecycleToWrite
            ),
            disposition: .written,
            committedSession: sessionToSave
        )
    }

    #if DEBUG
        /// `save.session.written`: one successful full-session replacement by `saveAgentSessionLocked`.
        /// Schedule mutations, accepted-send finalization, and load/migration rewrites also replace
        /// session files but are deliberately not counted. `writerAwait` is awaited writer latency
        /// (queueing and coalescing included), not disk-only time. Fields carry no content or paths.
        private static func recordFullSessionWrittenDiagnostics(
            _ session: AgentSession,
            encodedByteCount: Int,
            committingTranscriptReset: Bool,
            prepareStartMS: Double?,
            encodeStartMS: Double?,
            writeStartMS: Double?
        ) {
            guard let prepareStartMS, let encodeStartMS, let writeStartMS else { return }
            let writtenMS = AgentModePerfDiagnostics.timestampMS()
            AgentModePerfDiagnostics.increment("save.session.written", tabID: session.composeTabID)
            AgentModePerfDiagnostics.event(
                "save.session.written",
                tabID: session.composeTabID,
                fields: [
                    "sessionID": AgentModePerfDiagnostics.shortID(session.id),
                    "duration": AgentModePerfDiagnostics.formatMS(writtenMS - prepareStartMS),
                    "prepare": AgentModePerfDiagnostics.formatMS(encodeStartMS - prepareStartMS),
                    "encode": AgentModePerfDiagnostics.formatMS(writeStartMS - encodeStartMS),
                    "writerAwait": AgentModePerfDiagnostics.formatMS(writtenMS - writeStartMS),
                    "bytes": String(encodedByteCount),
                    "itemCount": session.itemCount.map(String.init) ?? "nil",
                    "turnCount": String(session.transcript?.turns.count ?? 0),
                    "transcriptReset": String(committingTranscriptReset)
                ]
            )
        }
    #endif

    /// Atomically compare-and-mutates the persisted scheduled-send member.
    ///
    /// All schedule mutations for one session are serialized through this API. A successful return
    /// always means the authoritative session file was durably replaced. Metadata-index failure is
    /// reported separately because retrying the already-committed mutation would be unsafe. Editable
    /// scheduling owners must use the persistence-stamp overload below.
    func mutateScheduledSend(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        mutation: AgentScheduledSendMutation
    ) async throws -> AgentScheduledSendMutationResult {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return try await performScheduledSendMutation(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: nil,
            mutation: mutation
        )
    }

    /// Fenced schedule-only mutation for an editable owner.
    package func mutateScheduledSend(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        persistenceStamp: AgentSessionPersistenceStamp,
        mutation: AgentScheduledSendMutation
    ) async throws -> AgentScheduledSendMutationResult {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return try await performScheduledSendMutation(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: persistenceStamp,
            mutation: mutation
        )
    }

    private func performScheduledSendMutation(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        persistenceStamp: AgentSessionPersistenceStamp?,
        mutation: AgentScheduledSendMutation
    ) async throws -> AgentScheduledSendMutationResult {
        let agentSessionsFolder: URL
        let fileURL: URL
        if let persistenceStamp {
            try validatePersistenceStamp(
                persistenceStamp,
                sessionID: sessionID,
                workspaceID: workspace.id
            )
            fileURL = persistenceStamp.fileURL
            agentSessionsFolder = fileURL.deletingLastPathComponent()
        } else {
            agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
            fileURL = agentSessionFileURL(id: sessionID, in: agentSessionsFolder)
        }
        try requireNoTombstone(for: sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionNotFound(sessionID)
        }

        var session = try await loadAgentSessionLocked(from: fileURL, purpose: .storageMutation)
        if let persistenceStamp {
            try validateStampIncarnation(persistenceStamp, against: session)
        }

        switch mutation {
        case let .upsert(expectedUpdatedAt, value):
            let actualUpdatedAt: Date?
            switch session.scheduledSend {
            case nil:
                actualUpdatedAt = nil
            case let .v1(current):
                actualUpdatedAt = current.updatedAt
            case .unreadable:
                throw AgentScheduledSendMutationError.unreadableScheduledSend(sessionID)
            }
            guard expectedUpdatedAt == actualUpdatedAt else {
                throw AgentScheduledSendMutationError.staleExpectedUpdatedAt(
                    expected: expectedUpdatedAt,
                    actual: actualUpdatedAt
                )
            }
            session.scheduledSend = .v1(value)
        case let .clear(expectedUpdatedAt, completedDispatch):
            let actualUpdatedAt: Date?
            switch session.scheduledSend {
            case nil:
                actualUpdatedAt = nil
            case let .v1(current):
                actualUpdatedAt = current.updatedAt
            case .unreadable:
                throw AgentScheduledSendMutationError.unreadableScheduledSend(sessionID)
            }
            guard actualUpdatedAt == expectedUpdatedAt else {
                throw AgentScheduledSendMutationError.staleExpectedUpdatedAt(
                    expected: expectedUpdatedAt,
                    actual: actualUpdatedAt
                )
            }
            session.scheduledSend = nil
            if let completedDispatch {
                session.lastScheduledDispatch = completedDispatch
            }
        case let .discardUnreadable(expected):
            let expectedMember = AgentScheduledSendMember.unreadable(expected)
            guard session.scheduledSend == expectedMember else {
                throw AgentScheduledSendMutationError.staleExpectedScheduledSendMember(
                    expected: expectedMember,
                    actual: session.scheduledSend
                )
            }
            session.scheduledSend = nil
        }

        let sessionToSave = Self.sessionPreparedForStorage(
            session,
            fileURL: fileURL,
            savedAt: Date(),
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: session.itemCount
        )
        let data = try AgentSessionDataCodec.encodeSession(sessionToSave, using: JSONEncoder())
        try await writeDataAtomically(data, to: fileURL)
        rememberScheduleAuthority(from: sessionToSave, fileURL: fileURL)
        rememberLifecycle(of: sessionToSave, fileURL: fileURL)

        let indexStatus: AgentScheduledSendMutationResult.MetadataIndexStatus =
            switch await upsertMetadataRecordReporting(
                metadataRecord(from: sessionToSave, fileURL: fileURL),
                folder: agentSessionsFolder
            ) {
            case .success:
                .updated
            case let .failure(error):
                .repairNeeded(String(describing: error))
            }

        return AgentScheduledSendMutationResult(
            session: sessionToSave,
            fileURL: fileURL,
            metadataIndexStatus: indexStatus
        )
    }

    /// Atomically commits an accepted scheduled user turn and retires its durable schedule.
    ///
    /// The immutable schedule revision and exact dispatch attempt are validated under the same
    /// per-session persistence gate used by ordinary saves. A successful return means the user
    /// item (with provenance), dispatch receipt, and schedule removal are in one durable session
    /// replacement. Matching retries are persistence-idempotent and never authorize provider work.
    func finalizeScheduledSend(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt,
        acceptedUserItem: AgentChatItem,
        receipt: AgentScheduledSendProvenance
    ) async throws -> AgentScheduledSendMutationResult {
        await acquireSessionPersistence(for: sessionID)
        do {
            let result = try await performScheduledSendFinalization(
                sessionID: sessionID,
                for: workspace,
                expectedUpdatedAt: expectedUpdatedAt,
                expectedAttempt: expectedAttempt,
                acceptedUserItem: acceptedUserItem,
                receipt: receipt
            )
            releaseSessionPersistence(for: sessionID)
            return result
        } catch {
            releaseSessionPersistence(for: sessionID)
            throw error
        }
    }

    /// Captures a DataService-issued recovery context for a persisted `.dispatching` attempt
    /// under the session gate: the pinned destination, the current explicit-deletion generation,
    /// and the canonical session snapshot used only for accidental missing-file reconstruction.
    /// Provider-handoff callers must use the persistence-stamp overload below.
    func prepareScheduledSendRecovery(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt
    ) async throws -> AgentScheduledSendRecoveryContext {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return try await prepareScheduledSendRecoveryLocked(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: nil,
            expectedUpdatedAt: expectedUpdatedAt,
            expectedAttempt: expectedAttempt
        )
    }

    /// Fenced recovery preparation for an editable owner.
    package func prepareScheduledSendRecovery(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        persistenceStamp: AgentSessionPersistenceStamp,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt
    ) async throws -> AgentScheduledSendRecoveryContext {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return try await prepareScheduledSendRecoveryLocked(
            sessionID: sessionID,
            for: workspace,
            persistenceStamp: persistenceStamp,
            expectedUpdatedAt: expectedUpdatedAt,
            expectedAttempt: expectedAttempt
        )
    }

    private func prepareScheduledSendRecoveryLocked(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        persistenceStamp: AgentSessionPersistenceStamp?,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt
    ) async throws -> AgentScheduledSendRecoveryContext {
        let agentSessionsFolder: URL
        let fileURL: URL
        if let persistenceStamp {
            try validatePersistenceStamp(
                persistenceStamp,
                sessionID: sessionID,
                workspaceID: workspace.id
            )
            fileURL = persistenceStamp.fileURL
            agentSessionsFolder = fileURL.deletingLastPathComponent()
        } else {
            agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
            fileURL = agentSessionFileURL(id: sessionID, in: agentSessionsFolder)
        }
        let fileKey = canonicalSessionFileKey(fileURL)
        try requireNoTombstone(for: sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionNotFound(sessionID)
        }
        let session = try await loadAgentSessionLocked(from: fileURL, purpose: .storageMutation)
        if let persistenceStamp {
            try validateStampIncarnation(persistenceStamp, against: session)
        }
        guard let lifecycle = session.lifecycle?.lifecycle else {
            throw AgentScheduledSendMutationError.unreadableLifecycle(sessionID)
        }
        guard let record = session.scheduledSend?.persistedValue else {
            throw AgentScheduledSendMutationError.staleExpectedUpdatedAt(expected: expectedUpdatedAt, actual: nil)
        }
        guard record.updatedAt == expectedUpdatedAt else {
            throw AgentScheduledSendMutationError.staleExpectedUpdatedAt(expected: expectedUpdatedAt, actual: record.updatedAt)
        }
        guard record.attempt == expectedAttempt else {
            throw AgentScheduledSendMutationError.staleExpectedAttempt(expected: expectedAttempt, actual: record.attempt)
        }
        guard record.state == .dispatching else {
            throw AgentScheduledSendMutationError.scheduledSendNotDispatching(actual: record.state)
        }
        let snapshot = try AgentSessionDataCodec.encodeSession(session, using: JSONEncoder())
        return AgentScheduledSendRecoveryContext(
            sessionID: sessionID,
            workspaceID: workspace.id,
            workspace: workspace,
            fileURL: fileURL,
            fileKey: fileKey,
            agentSessionsFolderURL: agentSessionsFolder,
            deletionGeneration: deletionGenerationsByFileKey[fileKey] ?? 0,
            incarnationID: lifecycle.incarnationID,
            canonicalSessionSnapshot: snapshot,
            transcriptResetReceiptAtPreparation: lifecycle.lastTranscriptResetReceipt,
            transcriptResetGenerationAtPreparation: lifecycle.transcriptResetGeneration,
            dataService: self
        )
    }

    /// Recovery finalization at the pinned destination, under the same gate and through the same
    /// accepted-item/receipt/schedule-retirement pipeline as `finalizeScheduledSend`. Deletion
    /// evidence (durable tombstone, then process-local generation) is checked first. An existing
    /// file must still be the captured incarnation; a later durable reset suppresses accepted items
    /// absent from the post-reset transcript. A missing file is reconstructed only while this
    /// service still holds authoritative lifecycle/reset state for the destination (selecting the
    /// post-reset snapshot when a later reset committed); otherwise it fails closed with
    /// `lifecycleAuthorityUnavailable`. Identity is never minted from a recovery snapshot, and an
    /// existing file is never overwritten wholesale.
    func finalizeScheduledSend(
        recovery payload: AgentScheduledSendAcceptedPayload
    ) async throws -> AgentScheduledSendRecoveryOutcome {
        let context = payload.context
        guard context.dataService === self else {
            throw AgentScheduledSendMutationError.invalidPersistenceStamp
        }
        await acquireSessionPersistence(for: context.sessionID)
        defer { releaseSessionPersistence(for: context.sessionID) }
        let fileKey = canonicalSessionFileKey(context.fileURL)
        switch try tombstoneState(for: context.sessionID) {
        case .absent:
            break
        case .committed:
            return .explicitlyDeleted
        case .unreadable:
            throw AgentScheduledSendMutationError.unreadableTombstone(context.sessionID)
        }
        let currentDeletionGeneration = deletionGenerationsByFileKey[fileKey] ?? 0
        guard currentDeletionGeneration == context.deletionGeneration else {
            return .explicitlyDeleted
        }
        #if DEBUG
            if let injected = test_scheduledSendRecoveryFailureInjector?(payload) {
                throw injected
            }
        #endif
        try validateAcceptedScheduledSendEvidence(
            expectedAttempt: payload.attempt,
            acceptedUserItem: payload.acceptedItem,
            receipt: payload.receipt
        )
        if FileManager.default.fileExists(atPath: context.fileURL.path) {
            let session = try await loadAgentSessionLocked(from: context.fileURL, purpose: .storageMutation)
            guard let lifecycle = session.lifecycle?.lifecycle,
                  lifecycle.incarnationID == context.incarnationID
            else {
                throw AgentScheduledSendMutationError.staleIncarnation(
                    expected: context.incarnationID,
                    actual: session.lifecycle?.lifecycle?.incarnationID
                )
            }
            let laterResetCommitted =
                lifecycle.transcriptResetGeneration > context.transcriptResetGenerationAtPreparation
            let result = try await commitScheduledSendFinalization(
                session: session,
                fileURL: context.fileURL,
                agentSessionsFolder: context.agentSessionsFolderURL,
                expectedUpdatedAt: payload.expectedUpdatedAt,
                expectedAttempt: payload.attempt,
                acceptedUserItem: payload.acceptedItem,
                receipt: payload.receipt,
                suppressAcceptedItem: laterResetCommitted
                    && !sessionContainsItem(session, itemID: payload.attempt.itemID)
            )
            return .committed(result)
        }
        // Missing file: only this service's authoritative lifecycle for the same incarnation can
        // decide which snapshot is current.
        guard let authoritativeLifecycle = lifecycleByFileKey[fileKey],
              authoritativeLifecycle.incarnationID == context.incarnationID,
              authoritativeLifecycle.transcriptResetGeneration >= context.transcriptResetGenerationAtPreparation
        else {
            throw AgentScheduledSendRecoveryError.lifecycleAuthorityUnavailable
        }
        let laterResetAuthority: AgentSessionTranscriptResetAuthority?
        if authoritativeLifecycle.transcriptResetGeneration > context.transcriptResetGenerationAtPreparation {
            guard let authority = transcriptResetAuthorityByFileURL[fileKey],
                  authority.incarnationID == authoritativeLifecycle.incarnationID,
                  authority.generation == authoritativeLifecycle.transcriptResetGeneration
            else {
                throw AgentScheduledSendRecoveryError.lifecycleAuthorityUnavailable
            }
            laterResetAuthority = authority
        } else {
            laterResetAuthority = nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: context.agentSessionsFolderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw AgentScheduledSendRecoveryError.destinationUnavailable(context.agentSessionsFolderURL)
        }
        let recoverySnapshotData =
            laterResetAuthority?.canonicalSessionSnapshot ?? context.canonicalSessionSnapshot
        var snapshot: AgentSession
        do {
            snapshot = try AgentSessionDataCodec.decodeSession(from: recoverySnapshotData)
        } catch {
            throw AgentScheduledSendRecoveryError.snapshotUndecodable
        }
        if let scheduleAuthority = scheduleAuthorityByFileURL[fileKey] {
            snapshot = sessionByApplyingScheduleAuthority(scheduleAuthority, to: snapshot)
        }
        // Retain the authoritative lifecycle and reset receipt; never the snapshot's own member.
        snapshot.lifecycle = .v1(authoritativeLifecycle)
        let result = try await commitScheduledSendFinalization(
            session: snapshot,
            fileURL: context.fileURL,
            agentSessionsFolder: context.agentSessionsFolderURL,
            expectedUpdatedAt: payload.expectedUpdatedAt,
            expectedAttempt: payload.attempt,
            acceptedUserItem: payload.acceptedItem,
            receipt: payload.receipt,
            suppressAcceptedItem: laterResetAuthority != nil
                && !sessionContainsItem(snapshot, itemID: payload.attempt.itemID)
        )
        return .committed(result)
    }

    private func validateAcceptedScheduledSendEvidence(
        expectedAttempt: AgentScheduledSendPersist.Attempt,
        acceptedUserItem: AgentChatItem,
        receipt: AgentScheduledSendProvenance
    ) throws {
        guard acceptedUserItem.id == expectedAttempt.itemID else {
            throw AgentScheduledSendMutationError.invalidAcceptedUserItem(
                expectedItemID: expectedAttempt.itemID,
                actualItemID: acceptedUserItem.id
            )
        }
        guard acceptedUserItem.kind == .user else {
            throw AgentScheduledSendMutationError.acceptedItemNotUser(acceptedUserItem.id)
        }
        guard acceptedUserItem.scheduledSend == nil || acceptedUserItem.scheduledSend == receipt,
              receipt.attemptID == expectedAttempt.attemptID
        else {
            throw AgentScheduledSendMutationError.invalidDispatchReceipt
        }
    }

    private func performScheduledSendFinalization(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt,
        acceptedUserItem: AgentChatItem,
        receipt: AgentScheduledSendProvenance
    ) async throws -> AgentScheduledSendMutationResult {
        try validateAcceptedScheduledSendEvidence(
            expectedAttempt: expectedAttempt,
            acceptedUserItem: acceptedUserItem,
            receipt: receipt
        )

        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionFileURL(id: sessionID, in: agentSessionsFolder)
        try requireNoTombstone(for: sessionID)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionNotFound(sessionID)
        }
        let session = try await loadAgentSessionLocked(from: fileURL, purpose: .storageMutation)
        return try await commitScheduledSendFinalization(
            session: session,
            fileURL: fileURL,
            agentSessionsFolder: agentSessionsFolder,
            expectedUpdatedAt: expectedUpdatedAt,
            expectedAttempt: expectedAttempt,
            acceptedUserItem: acceptedUserItem,
            receipt: receipt
        )
    }

    /// Shared, gate-held finalization pipeline for a loaded authoritative session (existing file)
    /// or the canonical reconstruction snapshot (accidentally missing file).
    private func commitScheduledSendFinalization(
        session loadedSession: AgentSession,
        fileURL: URL,
        agentSessionsFolder: URL,
        expectedUpdatedAt: Date,
        expectedAttempt: AgentScheduledSendPersist.Attempt,
        acceptedUserItem: AgentChatItem,
        receipt: AgentScheduledSendProvenance,
        suppressAcceptedItem: Bool = false
    ) async throws -> AgentScheduledSendMutationResult {
        var stampedItem = acceptedUserItem
        stampedItem.scheduledSend = receipt
        var session = loadedSession
        let fileKey = canonicalSessionFileKey(fileURL)
        var itemAuthorityForCommit = scheduleAuthorityByFileURL[fileKey]
        let exactRemovalWasCommitted =
            itemAuthorityForCommit?
                .intentionallyRemovedAcceptedUserItemReceiptsByID[stampedItem.id] == receipt
        let acceptedItemMustRemainAbsent = exactRemovalWasCommitted || suppressAcceptedItem
        if suppressAcceptedItem, !exactRemovalWasCommitted {
            var authority = itemAuthorityForCommit ?? AgentSessionScheduleAuthority(
                scheduledSend: session.scheduledSend,
                lastScheduledDispatch: session.lastScheduledDispatch,
                protectedAcceptedUserItemsByID: [:],
                intentionallyRemovedAcceptedUserItemReceiptsByID: [:]
            )
            authority.protectedAcceptedUserItemsByID.removeValue(forKey: stampedItem.id)
            authority.intentionallyRemovedAcceptedUserItemReceiptsByID[stampedItem.id] = receipt
            itemAuthorityForCommit = authority
        }
        var shouldRetirePersistedSchedule = false

        switch session.scheduledSend {
        case let .v1(record):
            let matchesAcceptedSchedule = record.id == receipt.scheduleID
            let matchesAcceptedAttempt = record.attempt == expectedAttempt
            if matchesAcceptedSchedule, matchesAcceptedAttempt {
                guard receipt.scheduledFor == record.notBefore else {
                    throw AgentScheduledSendMutationError.invalidDispatchReceipt
                }
                // Internal schedule-state persistence may advance updatedAt after provider
                // acceptance. The immutable attempt, not that mutable revision, identifies
                // the pending work that this persistence-only finalization must retire.
                shouldRetirePersistedSchedule = true
            } else if matchesAcceptedSchedule, record.updatedAt == expectedUpdatedAt {
                throw AgentScheduledSendMutationError.staleExpectedAttempt(
                    expected: expectedAttempt,
                    actual: record.attempt
                )
            }
        // A different schedule or attempt is a genuine successor. Preserve it while
        // completing the accepted predecessor's item and receipt below.
        case nil, .unreadable:
            // A prior partial write, cancellation, or successor from a future schema must
            // not reduce accepted-message recovery to receipt-only success. Complete the
            // durable item and receipt while leaving any unknown member untouched.
            break
        }

        if acceptedItemMustRemainAbsent {
            session = sessionByRemovingIntentionallyRemovedAcceptedUserItems(
                [stampedItem.id: receipt],
                from: session
            )
        } else {
            session = sessionByMergingProtectedAcceptedUserItems(
                [stampedItem.id: stampedItem],
                into: session
            )
        }
        if shouldRetirePersistedSchedule {
            session.scheduledSend = nil
        }
        session.lastScheduledDispatch = receipt
        let sessionToSave = Self.sessionPreparedForStorage(
            session,
            fileURL: fileURL,
            savedAt: Date(),
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: nil
        )
        let data = try AgentSessionDataCodec.encodeSession(sessionToSave, using: JSONEncoder())
        try await writeDataAtomically(data, to: fileURL)
        rememberScheduleAuthority(
            from: sessionToSave,
            fileURL: fileURL,
            protecting: acceptedItemMustRemainAbsent ? nil : stampedItem,
            preservingItemAuthority: itemAuthorityForCommit
        )
        rememberLifecycle(of: sessionToSave, fileURL: fileURL)

        let indexStatus: AgentScheduledSendMutationResult.MetadataIndexStatus =
            switch await upsertMetadataRecordReporting(
                metadataRecord(from: sessionToSave, fileURL: fileURL),
                folder: agentSessionsFolder
            ) {
            case .success:
                .updated
            case let .failure(error):
                .repairNeeded(String(describing: error))
            }

        return AgentScheduledSendMutationResult(
            session: sessionToSave,
            fileURL: fileURL,
            metadataIndexStatus: indexStatus
        )
    }

    // MARK: - Recovery lifecycle gate (lossless restart Phase 1b, inactive)

    /// Whether `store` is this service's configured recovery store (composition check: gates and
    /// tombstone-aware discovery must validate against the same store the coordinator writes).
    package nonisolated func usesRecoveryStore(_ store: AgentRecoveryStore) -> Bool {
        recoveryStore === store
    }

    /// A recovery gate for one editable session's persistence state. Requires lifecycle authority.
    package nonisolated func recoveryLifecycleGate(
        for state: AgentSessionPersistenceState
    ) throws -> AgentSessionRecoveryLifecycleGate {
        guard let incarnationID = state.stamp.incarnationID else {
            throw AgentScheduledSendMutationError.missingLifecycle(state.stamp.sessionID)
        }
        return AgentSessionRecoveryLifecycleGate(
            service: self,
            persistenceState: state,
            binding: AgentRecoveryLifecycleBinding(
                sessionID: state.stamp.sessionID,
                incarnationID: incarnationID,
                transcriptResetGeneration: state.transcriptResetGeneration
            )
        )
    }

    /// Runs `body` under the session persistence gate after validating `state` against current
    /// durable authority; rejects (before `body`) after deletion, reset, or incarnation change.
    func performRecoveryTransaction<T: Sendable>(
        persistenceState state: AgentSessionPersistenceState,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let sessionID = state.stamp.sessionID
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        let stamp = state.stamp
        try validatePersistenceStamp(stamp, sessionID: sessionID, workspaceID: stamp.workspaceID)
        try requireNoTombstone(for: sessionID)
        guard FileManager.default.fileExists(atPath: stamp.fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionNotFound(sessionID)
        }
        guard case let .v1(current) = try currentDurableLifecycle(fileURL: stamp.fileURL, sessionID: sessionID) else {
            throw AgentScheduledSendMutationError.staleIncarnation(expected: stamp.incarnationID, actual: nil)
        }
        guard stamp.incarnationID == current.incarnationID else {
            throw AgentScheduledSendMutationError.staleIncarnation(expected: stamp.incarnationID, actual: current.incarnationID)
        }
        guard state.transcriptResetGeneration == current.transcriptResetGeneration else {
            throw AgentScheduledSendMutationError.staleTranscriptResetGeneration(
                expected: state.transcriptResetGeneration,
                actual: current.transcriptResetGeneration
            )
        }
        return try await body()
    }

    /// Runs `body` under the session persistence gate for a session with no live lane (a closed
    /// session's recovery-card acknowledgement), after validating `binding` against current durable
    /// authority: no tombstone, the session file present in `workspace`, and the same incarnation
    /// and reset generation. Rejects before `body` otherwise. Same lock order as live lanes.
    package func performClosedRecoveryTransaction<T: Sendable>(
        binding: AgentRecoveryLifecycleBinding,
        workspace: AgentRecoveryWorkspaceDestination,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let sessionID = binding.sessionID
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        try requireNoTombstone(for: sessionID)
        let fileURL = agentSessionFileURL(id: sessionID, in: existingAgentSessionsFolder(for: workspace))
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionNotFound(sessionID)
        }
        guard case let .v1(current) = try currentDurableLifecycle(fileURL: fileURL, sessionID: sessionID) else {
            throw AgentScheduledSendMutationError.staleIncarnation(expected: binding.incarnationID, actual: nil)
        }
        guard binding.incarnationID == current.incarnationID else {
            throw AgentScheduledSendMutationError.staleIncarnation(expected: binding.incarnationID, actual: current.incarnationID)
        }
        guard binding.transcriptResetGeneration == current.transcriptResetGeneration else {
            throw AgentScheduledSendMutationError.staleTranscriptResetGeneration(
                expected: binding.transcriptResetGeneration,
                actual: current.transcriptResetGeneration
            )
        }
        return try await body()
    }

    /// R5 stamp evidence for a gate-held cold load: the session's recovery run attempts (an absent or
    /// unreadable record contributes none, so the stamp says `unknown` without a run ID). `nil` when
    /// no recovery store is composed (legacy behavior: no stamp). Callers hold the session gate.
    private func coldRestoreInterruptionContext(sessionID: UUID) async -> AgentColdRestoreInterruptionContext? {
        guard let recoveryStore else { return nil }
        let currentInstanceID = recoveryStore.appInstanceID
        let launchStateCaptured = coldRestoreLaunchEvidence != nil
        let launchReason = coldRestoreLaunchEvidence.flatMap {
            AgentColdRestoreInterruptionContext.launchReason(previousLaunch: $0, currentInstanceID: currentInstanceID)
        }
        let provisional = provisionalUnknownStampTurnIDs[sessionID] ?? []
        guard let record = await recoveryStore.read(sessionID: sessionID).record else {
            return AgentColdRestoreInterruptionContext(
                observedAt: Date(),
                providerConversationID: nil,
                runAttempts: [],
                launchReason: launchReason,
                launchStateCaptured: launchStateCaptured,
                provisionalUnknownTurnIDs: provisional,
                currentInstanceID: currentInstanceID
            )
        }
        // R1a: no affirmative acceptance (queued, failed, dispatching, unknown, or withdrawn) from an
        // earlier launch: the saved deterministic bubble is never shown as sent. Verified
        // non-delivery reads as not sent; a handoff that may have happened reads as unconfirmed.
        let unaccepted = record.intents.compactMap { intent -> AgentColdRestoreInterruptionContext.UnacceptedBubble? in
            guard intent.deliveryState != .providerAccepted, intent.appInstanceID != currentInstanceID else { return nil }
            return AgentColdRestoreInterruptionContext.UnacceptedBubble(
                userItemID: intent.userItemID,
                incarnationID: record.incarnationID,
                transcriptResetGeneration: intent.transcriptResetGeneration,
                delivery: AgentColdRestoreInterruptionContext.unacceptedDelivery(
                    state: intent.deliveryState,
                    attempts: record.attempts(forIntent: intent.intentID),
                    runsEndedWithRecordedEvidence: record.intentRunsEndedWithRecordedEvidence(intentID: intent.intentID)
                )
            )
        }
        let bubbles = record.intents.compactMap { intent -> AgentColdRestoreInterruptionContext.AcceptedBubble? in
            // Only affirmative acceptance from an earlier launch; this launch's own optimistic
            // bubbles are owned by their live view model.
            guard intent.deliveryState == .providerAccepted, intent.appInstanceID != currentInstanceID else { return nil }
            return AgentColdRestoreInterruptionContext.AcceptedBubble(
                userItemID: intent.userItemID,
                incarnationID: record.incarnationID,
                transcriptResetGeneration: intent.transcriptResetGeneration,
                text: intent.payload.text,
                attachments: intent.payload.images.compactMap { recoveryStore.attachment(for: $0, sessionID: sessionID) },
                taggedFiles: intent.payload.taggedFiles.map(\.attachment),
                documents: intent.payload.documents.map(\.attachment),
                workflow: intent.payload.workflow?.definition
            )
        }
        return AgentColdRestoreInterruptionContext(
            observedAt: Date(),
            providerConversationID: nil,
            runAttempts: record.runAttempts,
            intentAttempts: record.attempts,
            acceptedBubbles: bubbles,
            unacceptedBubbles: unaccepted,
            launchReason: launchReason,
            launchStateCaptured: launchStateCaptured,
            provisionalUnknownTurnIDs: provisional,
            // F-7: this launch's live runs (and their exact turns) are excluded from the cold
            // restoration; the rest of the record is still applied.
            currentInstanceID: currentInstanceID
        )
    }

    /// Adopts the previous-launch state the recovery coordinator captured (before this launch's
    /// mark replaced it) as R5 launch evidence. First capture wins; until then stamps say `unknown`
    /// provisionally and are refined by a later gate-held load.
    package func adoptColdRestoreLaunchEvidence(_ previousLaunch: AgentRecoveryPreviousLaunch) {
        guard coldRestoreLaunchEvidence == nil else { return }
        coldRestoreLaunchEvidence = previousLaunch
    }

    /// After a committed cold load: remembers turns stamped `unknown` only because launch evidence
    /// was not captured yet, or forgets them once a load with evidence refined them. (Turns closed as
    /// an ordinary outcome carry their own durable `recoveredOutcome` marker.)
    private func noteColdRestoreStamps(
        sessionID: UUID,
        context: AgentColdRestoreInterruptionContext?,
        transcript: AgentTranscript?
    ) {
        guard let context else { return }
        if context.launchStateCaptured {
            if context.launchReason != nil {
                provisionalUnknownStampTurnIDs[sessionID] = nil
            }
            return
        }
        let stamped = (transcript?.turns ?? []).filter { turn in
            guard let interruption = turn.interruption else { return false }
            return interruption.observedAt == context.observedAt
                && interruption.reason == .unknown
                && interruption.resolution == nil
        }.map(\.id)
        guard !stamped.isEmpty else { return }
        provisionalUnknownStampTurnIDs[sessionID, default: []].formUnion(stamped)
    }

    // MARK: - Startup reconciliation (lossless restart Phase 1b)

    /// The workspace's session folder, resolved without creating anything.
    private func existingAgentSessionsFolder(for workspace: some AgentWorkspaceStorageReference) -> URL {
        agentSessionsFolderURL(for: workspace)
    }

    /// Index-only session metadata for the recovery catalog's schedule discovery (lossless restart
    /// Phase 2), read through the same cache as startup discovery: creates no folder, rebuilds no
    /// index, and hydrates nothing. `[]` when the workspace has no session folder or session files;
    /// `nil` when session files exist but no current or schedule-compatible older index describes
    /// them (discovery incomplete).
    package func recoveryIndexedSessionRecords(
        for workspace: some AgentWorkspaceStorageReference
    ) async -> [AgentSessionMetadataRecord]? {
        let folder = existingAgentSessionsFolder(for: workspace)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        if let index = await readMetadataIndexIfAvailable(folder: folder) {
            return try? excludingTombstoned(index.entries.sortedForAgentSessionMetadataIndex())
        }
        if let older = readScheduleCompatibleOlderMetadataIndex(folder: folder) {
            return try? excludingTombstoned(older.entries.sortedForAgentSessionMetadataIndex())
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { agentSessionID(fromFilename: $0) != nil } ? nil : []
    }

    /// Oldest index schema whose `scheduledSendSummary` has the current shape (review B F4): schema 7
    /// predates only the schema-8 recovery hint, which schedule discovery never reads.
    private static let oldestScheduleCompatibleMetadataIndexSchemaVersion = 7

    /// Read-only schedule discovery from a decodable older index left by a previous build in a
    /// workspace this launch has not opened (review B F4). Never cached, rebuilt, or rewritten: the
    /// ordinary current-schema read path still treats it as absent and rebuilds it on open.
    private func readScheduleCompatibleOlderMetadataIndex(folder: URL) -> AgentSessionMetadataIndex? {
        let fileURL = metadataIndexFileURL(forAgentSessionsFolder: folder)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let index = try? decoder.decode(AgentSessionMetadataIndex.self, from: data),
              index.schemaVersion >= Self.oldestScheduleCompatibleMetadataIndexSchemaVersion,
              index.schemaVersion < AgentSessionMetadataIndex.currentSchemaVersion
        else { return nil }
        return index
    }

    /// Every normal session file of `workspace` (full sessions and durable stubs share one file
    /// format), each with a metadata-index hint only when the index entry still describes the file
    /// on disk. Creates nothing. A default-location workspace without a folder has no sessions; an
    /// unreachable custom location or an unreadable folder throws (a scoped workspace failure).
    package func recoverySessionFiles(
        for workspace: some AgentWorkspaceStorageReference
    ) async throws -> [AgentRecoverySessionFile] {
        let folder = existingAgentSessionsFolder(for: workspace)
        if let customURL = workspace.customStoragePath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: customURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: customURL.path])
            }
        }
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let index = await readMetadataIndexIfAvailable(folder: folder)
        var entriesByID: [UUID: AgentSessionMetadataRecord] = [:]
        for entry in index?.entries ?? [] where entriesByID[entry.id] == nil {
            entriesByID[entry.id] = entry
        }
        return names.compactMap { agentSessionID(fromFilename: $0) }
            .sorted { $0.uuidString < $1.uuidString }
            .map { sessionID in
                let fileURL = agentSessionFileURL(id: sessionID, in: folder)
                guard let entry = entriesByID[sessionID] else {
                    return AgentRecoverySessionFile(sessionID: sessionID, hint: nil)
                }
                let observed = metadataResourceValues(for: fileURL)
                guard let size = observed.size, let modified = observed.modified,
                      entry.observedFileSize == size, entry.observedFileModificationDate == modified
                else {
                    // A stale entry may describe an older file: inspect the session itself.
                    return AgentRecoverySessionFile(sessionID: sessionID, hint: nil)
                }
                return AgentRecoverySessionFile(sessionID: sessionID, hint: AgentRecoverySessionFileHint(
                    lastRunStateRaw: entry.lastRunStateRaw,
                    scheduleStateRaw: entry.scheduledSendSummary?.stateRaw,
                    scheduleUnreadable: entry.hasUnreadableScheduledSend,
                    // Only a hint whose every input was inspected and clear skips inspection; a
                    // stub-built entry (unknown transcript part) is inspected once (the load
                    // re-indexes it). Recovery records are inspected regardless of any hint.
                    mayHaveUnresolvedInterruption: entry.recoveryHint.state != .none
                ))
            }
    }

    /// Reconciles one session at startup under its session gate (spec R1a, R5, R9): validates the
    /// tombstone, session file, recovery record, and lifecycle authority before any load, so a
    /// mismatched or unreadable authority never normalizes the saved turn; then loads (stamping
    /// open turns and restoring accepted bubbles in the same rewrite) and repairs an unowned
    /// `.dispatching` schedule. Constructs no provider, controller, or view model, and never waits
    /// on a startup barrier. Every unresolved interruption is reported, whichever launch stamped it:
    /// repeated restarts keep its row and crash hold until it is resolved.
    package func reconcileRecoverySession(
        sessionID: UUID,
        workspace: AgentRecoveryWorkspaceDestination
    ) async -> AgentSessionRecoveryResolution {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return await reconcileRecoverySessionLocked(sessionID: sessionID, workspace: workspace)
    }

    private func reconcileRecoverySessionLocked(
        sessionID: UUID,
        workspace: AgentRecoveryWorkspaceDestination
    ) async -> AgentSessionRecoveryResolution {
        func resolution(_ classification: AgentSessionRecoveryClassification) -> AgentSessionRecoveryResolution {
            AgentSessionRecoveryResolution(sessionID: sessionID, workspaceID: workspace.id, classification: classification)
        }
        switch try? tombstoneState(for: sessionID) {
        case nil:
            return resolution(.nonactionable(.authorityUnreadable))
        case .committed, .unreadable:
            return resolution(.tombstoned)
        case .absent:
            break
        }
        let fileURL = agentSessionFileURL(id: sessionID, in: existingAgentSessionsFolder(for: workspace))
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return resolution(.nonactionable(.sessionFileUnavailable))
        }
        let recordState: AgentRecoveryRecordState = if let recoveryStore {
            await recoveryStore.read(sessionID: sessionID)
        } else {
            .absent
        }
        if case let .preserved(reason) = recordState {
            return resolution(.nonactionable(.unreadableRecord(reason)))
        }
        let durable: DurableLifecycleState
        do {
            durable = try currentDurableLifecycle(fileURL: fileURL, sessionID: sessionID)
        } catch {
            return resolution(.nonactionable(.authorityUnreadable))
        }
        if let record = recordState.record {
            guard case let .v1(lifecycle) = durable,
                  lifecycle.incarnationID == record.incarnationID,
                  lifecycle.transcriptResetGeneration >= record.transcriptResetGeneration
            else {
                return resolution(.nonactionable(.authorityMismatch))
            }
        }
        var session: AgentSession
        do {
            // Startup reconciliation is the cold restoration of a closed session.
            session = try await loadAgentSessionLocked(from: fileURL, purpose: .coldRestore)
        } catch {
            return resolution(.nonactionable(.authorityUnreadable))
        }
        guard case let .v1(lifecycle)? = session.lifecycle else {
            return resolution(.nonactionable(.authorityUnreadable))
        }
        let binding = AgentRecoveryLifecycleBinding(
            sessionID: sessionID,
            incarnationID: lifecycle.incarnationID,
            transcriptResetGeneration: lifecycle.transcriptResetGeneration
        )
        var discovered: AgentRecoveryDiscoveredRecord?
        if let record = recordState.record, let recoveryStore {
            let holds = await recoveryStore.derivedHolds(for: record, currentGeneration: lifecycle.transcriptResetGeneration)
            discovered = AgentRecoveryDiscoveredRecord(record: record, holdsByIntentID: holds)
        }
        let turns = session.transcript?.turns ?? []
        let attemptsByID = Dictionary(
            (recordState.record?.runAttempts ?? []).map { ($0.runAttemptID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let interruptedTurns = turns.compactMap { turn -> AgentRecoveryInterruptedTurn? in
            guard let interruption = turn.interruption, interruption.resolution == nil else { return nil }
            // The shared classifier: any terminal evidence is not completion (R5 Phase 2).
            let attempt = interruption.runAttemptID.flatMap { attemptsByID[$0] }
            return AgentRecoveryInterruptedTurn(
                turnID: turn.id,
                interruption: interruption,
                status: .classify(attempt: attempt),
                isLastTurn: turn.id == turns.last?.id
            )
        }
        // Turns saved open that a cold restoration (this launch's or an earlier one's) closed with
        // their attempt's ordinary outcome (review A F03 / F03-R1): the durable `recoveredOutcome`
        // marker lists them by that attempt, never as an interruption, on every launch until the
        // item's card acknowledgement (Dismiss) hides it.
        let outcomeTurns = turns.compactMap { turn -> AgentRecoveryOutcomeTurn? in
            guard let marker = turn.recoveredOutcome, turn.interruption == nil,
                  let attempt = attemptsByID[marker.runAttemptID], attempt.terminal != nil
            else { return nil }
            return AgentRecoveryOutcomeTurn(turnID: turn.id, runAttempt: attempt)
        }
        // Attempts the transcript never saved (R08 joins: own turn, or an unambiguous process run):
        // open ones, and terminal ones of this generation whose turn is missing (R09).
        let runAttempts = recordState.record?.runAttempts ?? []
        let recoveryOnlyRunAttempts = AgentRecoveryRunTurnJoin(
            runAttempts: runAttempts,
            intentAttempts: recordState.record?.attempts ?? []
        ).unrepresentedAttempts(
            runAttempts,
            in: turns,
            currentGeneration: lifecycle.transcriptResetGeneration
        )
        var transfer = AgentRecoveryScheduleTransferOutcome.notApplicable
        if case let .v1(schedule)? = session.scheduledSend, schedule.state == .dispatching {
            transfer = await repairScheduledSendTransferLocked(
                sessionID: sessionID,
                workspace: workspace,
                persistenceStamp: nil,
                expectedRecord: schedule
            )
            if transfer != .notApplicable,
               let reloaded = try? await loadAgentSessionLocked(from: fileURL, purpose: .storageMutation)
            {
                session = reloaded
            }
        }
        let resolved = AgentSessionRecoveryResolution(
            sessionID: sessionID,
            workspaceID: workspace.id,
            sessionName: session.name,
            composeTabID: session.composeTabID,
            classification: .actionable,
            binding: binding,
            record: discovered,
            interruptedTurns: interruptedTurns,
            outcomeTurns: outcomeTurns,
            recoveryOnlyRunAttempts: recoveryOnlyRunAttempts,
            scheduleTransfer: transfer,
            remoteHostID: session.remoteHost?.hostID,
            workspace: workspace
        )
        guard resolved.hasRecoveryItems || recordState.record != nil else {
            return resolution(.idle)
        }
        return resolved
    }

    /// Classifies a session the startup sweep cannot place in exactly one destination (a recovery
    /// record without a session file, or several session files), under its session gate: deletion
    /// residue behind a committed or unreadable tombstone is retired, an unreadable tombstone
    /// authority is unknown, and otherwise `unplaced` applies.
    package func classifyUnplacedRecoverySession(
        sessionID: UUID,
        unplaced: AgentSessionRecoveryClassification
    ) async -> AgentSessionRecoveryClassification {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        switch try? tombstoneState(for: sessionID) {
        case nil:
            return .nonactionable(.authorityUnreadable)
        case .committed, .unreadable:
            return .tombstoned
        case .absent:
            return unplaced
        }
    }

    /// R9 receipt-transfer repair of an unowned `.dispatching` schedule attempt, decided and committed
    /// under the session gate (the shared repair for closed sessions at startup and for hydrated
    /// owners). Completes the transfer in one CAS, normalizes to the delivery-unknown confirmation
    /// when nothing links to the attempt, and otherwise holds with the schedule unchanged. Never
    /// dispatches, confirms, or releases attachments.
    package func repairScheduledSendTransfer(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        persistenceStamp: AgentSessionPersistenceStamp,
        expectedRecord: AgentScheduledSendPersist
    ) async -> AgentRecoveryScheduleTransferOutcome {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        return await repairScheduledSendTransferLocked(
            sessionID: sessionID,
            workspace: workspace,
            persistenceStamp: persistenceStamp,
            expectedRecord: expectedRecord
        )
    }

    private func repairScheduledSendTransferLocked(
        sessionID: UUID,
        workspace: some AgentWorkspaceStorageReference,
        persistenceStamp: AgentSessionPersistenceStamp?,
        expectedRecord: AgentScheduledSendPersist
    ) async -> AgentRecoveryScheduleTransferOutcome {
        guard expectedRecord.state == .dispatching else { return .notApplicable }
        let fileURL = persistenceStamp?.fileURL
            ?? agentSessionFileURL(id: sessionID, in: existingAgentSessionsFolder(for: workspace))
        let session: AgentSession
        do {
            if let persistenceStamp {
                try validatePersistenceStamp(persistenceStamp, sessionID: sessionID, workspaceID: workspace.id)
            }
            try requireNoTombstone(for: sessionID)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .notApplicable }
            session = try await loadAgentSessionLocked(from: fileURL, purpose: .storageMutation)
            if let persistenceStamp {
                try validateStampIncarnation(persistenceStamp, against: session)
            }
        } catch {
            return .held("The scheduled message's session could not be read: \(error)")
        }
        guard case let .v1(current)? = session.scheduledSend, current == expectedRecord else { return .notApplicable }
        let recoveryRecord: AgentRecoveryRecordState = if let recoveryStore {
            await recoveryStore.read(sessionID: sessionID)
        } else {
            .absent
        }
        let mutation: AgentScheduledSendMutation
        let outcome: AgentRecoveryScheduleTransferOutcome
        switch AgentScheduledSendTransfer.resolve(record: current, recoveryRecord: recoveryRecord, sentAt: Date()) {
        case .noLinkedIntent, .rolledBack:
            let duplicateItemExists = current.attempt.map { sessionContainsItem(session, itemID: $0.itemID) } ?? false
            mutation = .upsert(
                expectedUpdatedAt: current.updatedAt,
                value: AgentScheduledSendTransfer.deliveryUnknownNormalization(of: current, duplicateItemExists: duplicateItemExists)
            )
            outcome = .normalized
        case let .hold(message):
            return .held(message)
        case let .completeTransfer(receipt):
            mutation = .clear(expectedUpdatedAt: current.updatedAt, completedDispatch: receipt)
            outcome = .completed(receipt)
        case .cancelTransfer:
            // R10: a committed cancellation decision is finished (also after a crash between its
            // write and this clear), never resent and never re-confirmed.
            mutation = .clear(expectedUpdatedAt: current.updatedAt, completedDispatch: nil)
            outcome = .cancelled
        }
        do {
            _ = try await performScheduledSendMutation(
                sessionID: sessionID,
                for: workspace,
                persistenceStamp: persistenceStamp,
                mutation: mutation
            )
            return outcome
        } catch {
            return .held("The scheduled message's transfer could not be saved: \(error)")
        }
    }

    /// R10 "Cancel pending schedule" for a held transfer, under the session gate: validates the
    /// exact pending `.dispatching` schedule attempt (`expectedRecord`) and the single linked intent
    /// whose own evidence holds it, commits the cancellation decision on that intent, then clears
    /// that exact schedule by CAS without any receipt. `.cancelled` only after the clear succeeds; a
    /// failed clear leaves the decision for the startup or owner repair to finish. `.notApplicable`
    /// when the schedule moved or the transfer is no longer held by that intent; `.held` on a read or
    /// write failure. Delivery evidence, attempts and attachments are never changed.
    package func cancelScheduledSendTransfer(
        sessionID: UUID,
        for workspace: some AgentWorkspaceStorageReference,
        persistenceStamp: AgentSessionPersistenceStamp,
        expectedRecord: AgentScheduledSendPersist
    ) async -> AgentRecoveryScheduleTransferOutcome {
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        guard expectedRecord.state == .dispatching, let attempt = expectedRecord.attempt, let recoveryStore else {
            return .notApplicable
        }
        let fileURL = persistenceStamp.fileURL
        let session: AgentSession
        let binding: AgentRecoveryLifecycleBinding
        do {
            try validatePersistenceStamp(persistenceStamp, sessionID: sessionID, workspaceID: workspace.id)
            try requireNoTombstone(for: sessionID)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return .notApplicable }
            session = try await loadAgentSessionLocked(from: fileURL, purpose: .storageMutation)
            try validateStampIncarnation(persistenceStamp, against: session)
            guard case let .v1(lifecycle) = try currentDurableLifecycle(fileURL: fileURL, sessionID: sessionID) else {
                return .held("The scheduled message's session has no readable lifecycle.")
            }
            binding = AgentRecoveryLifecycleBinding(
                sessionID: sessionID,
                incarnationID: lifecycle.incarnationID,
                transcriptResetGeneration: lifecycle.transcriptResetGeneration
            )
        } catch {
            return .held("The scheduled message's session could not be read: \(error)")
        }
        guard case let .v1(current)? = session.scheduledSend, current == expectedRecord else { return .notApplicable }
        let recoveryRecord = await recoveryStore.read(sessionID: sessionID)
        let resolution = AgentScheduledSendTransfer.resolve(record: current, recoveryRecord: recoveryRecord, sentAt: Date())
        if resolution != .cancelTransfer {
            guard let intentID = AgentScheduledSendTransfer.cancellableHeldTransferIntentID(
                record: current,
                recoveryRecord: recoveryRecord
            ) else { return .notApplicable }
            do {
                // Lock order: this session gate, then the recovery store.
                _ = try await recoveryStore.recordScheduledTransferCancellation(
                    binding: binding,
                    expectedRevision: recoveryRecord.record?.revision,
                    intentID: intentID,
                    scheduleID: current.id,
                    scheduleAttemptID: attempt.attemptID
                )
            } catch {
                return .held("The cancellation could not be saved: \(error)")
            }
        }
        do {
            _ = try await performScheduledSendMutation(
                sessionID: sessionID,
                for: workspace,
                persistenceStamp: persistenceStamp,
                mutation: .clear(expectedUpdatedAt: current.updatedAt, completedDispatch: nil)
            )
            return .cancelled
        } catch {
            return .held("The pending schedule could not be cleared: \(error)")
        }
    }

    /// Classifies every recovery record against this workspace's tombstones and session lifecycle,
    /// each under its session gate. Empty when no recovery store is configured.
    package func discoverRecoveryRecords(
        for workspace: some AgentWorkspaceStorageReference
    ) async throws -> [AgentSessionRecoveryDiscovery] {
        guard let recoveryStore else { return [] }
        let folder = try ensureAgentSessionsFolder(for: workspace)
        var results: [AgentSessionRecoveryDiscovery] = []
        for entry in try await recoveryStore.discoverRecords() {
            let sessionID: UUID
            switch entry {
            case let .preserved(preserved):
                guard let id = preserved.sessionID else {
                    results.append(.nonactionable(sessionID: nil, reason: .unreadableRecord(preserved.reason)))
                    continue
                }
                sessionID = id
            case let .supported(discovered):
                sessionID = discovered.record.sessionID
            }
            await acquireSessionPersistence(for: sessionID)
            let classification = await classifyRecoveryRecord(
                sessionID: sessionID,
                fileURL: agentSessionFileURL(id: sessionID, in: folder),
                store: recoveryStore
            )
            releaseSessionPersistence(for: sessionID)
            results.append(classification)
        }
        return results
    }

    /// Callers hold the session gate. Rereads the record under the gate.
    private func classifyRecoveryRecord(
        sessionID: UUID,
        fileURL: URL,
        store: AgentRecoveryStore
    ) async -> AgentSessionRecoveryDiscovery {
        switch try? tombstoneState(for: sessionID) {
        case nil:
            return .nonactionable(sessionID: sessionID, reason: .authorityUnreadable)
        case .committed, .unreadable:
            return .tombstoned(sessionID: sessionID)
        case .absent:
            break
        }
        let record: AgentRecoveryRecord
        switch await store.read(sessionID: sessionID) {
        case .absent:
            return .nonactionable(sessionID: sessionID, reason: .sessionFileUnavailable)
        case let .preserved(reason):
            return .nonactionable(sessionID: sessionID, reason: .unreadableRecord(reason))
        case let .supported(value):
            record = value
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .nonactionable(sessionID: sessionID, reason: .sessionFileUnavailable)
        }
        let durable: DurableLifecycleState
        do {
            durable = try currentDurableLifecycle(fileURL: fileURL, sessionID: sessionID)
        } catch {
            return .nonactionable(sessionID: sessionID, reason: .authorityUnreadable)
        }
        guard case let .v1(lifecycle) = durable,
              lifecycle.incarnationID == record.incarnationID,
              lifecycle.transcriptResetGeneration >= record.transcriptResetGeneration
        else {
            return .nonactionable(sessionID: sessionID, reason: .authorityMismatch)
        }
        let holds = await store.derivedHolds(for: record, currentGeneration: lifecycle.transcriptResetGeneration)
        return .eligible(
            AgentRecoveryDiscoveredRecord(record: record, holdsByIntentID: holds),
            binding: AgentRecoveryLifecycleBinding(
                sessionID: sessionID,
                incarnationID: lifecycle.incarnationID,
                transcriptResetGeneration: lifecycle.transcriptResetGeneration
            )
        )
    }

    private func acquireSessionPersistence(for sessionID: UUID) async {
        if activeSessionPersistence.insert(sessionID).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            sessionPersistenceWaiters[sessionID, default: []].append(continuation)
        }
    }

    private func releaseSessionPersistence(for sessionID: UUID) {
        guard var waiters = sessionPersistenceWaiters[sessionID], !waiters.isEmpty else {
            activeSessionPersistence.remove(sessionID)
            sessionPersistenceWaiters.removeValue(forKey: sessionID)
            return
        }
        let next = waiters.removeFirst()
        if waiters.isEmpty {
            sessionPersistenceWaiters.removeValue(forKey: sessionID)
        } else {
            sessionPersistenceWaiters[sessionID] = waiters
        }
        next.resume()
    }

    package func renameAgentSession(
        id: UUID,
        to newName: String,
        for workspace: some AgentWorkspaceStorageReference
    ) async throws {
        let validatedName = AgentSession.validatedName(newName)
        guard !validatedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard var session = try await loadAgentSession(id: id, for: workspace) else { return }
        guard session.name != validatedName else { return }
        session.name = validatedName
        _ = try await saveAgentSession(session, for: workspace)
    }

    package func rawLastRunStateForAgentSession(id: UUID, for workspace: some AgentWorkspaceStorageReference) async throws -> String? {
        let agentSessionsFolder = agentSessionsFolderURL(for: workspace)
        let fileURL = agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: id))
        // Tombstoned residue is never read as a session, like the other lookups by ID.
        guard try tombstoneState(for: id) == .absent,
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return nil }
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try AgentSessionDataCodec.decodeEnvelope(AgentSessionLastRunStateHeader.self, from: data, using: decoder)
            .value.lastRunState
    }

    /// Loads a session under the same per-session gate used by full saves and schedule CAS.
    func loadAgentSession(from fileURL: URL) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard let sessionID = agentSessionID(fromFilename: filename) else {
            throw AgentSessionDataError.invalidFilename(filename)
        }

        await acquireSessionPersistence(for: sessionID)
        do {
            // Resync, rename, and read-only tool loads: never a cold restoration (F-7).
            let session = try await loadAgentSessionLocked(from: fileURL, purpose: .storageMutation)
            releaseSessionPersistence(for: sessionID)
            return session
        } catch {
            releaseSessionPersistence(for: sessionID)
            throw error
        }
    }

    /// Gate-held load. Fences (tombstone, unsupported envelope, unreadable lifecycle) throw their
    /// typed errors before normalization or any rewrite. A legacy session receives fresh identity
    /// in the same replacement as its normalization; on write failure the original bytes remain
    /// and no identity escapes.
    private func loadAgentSessionLocked(from fileURL: URL, purpose: LoadPurpose) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard let sessionID = agentSessionID(fromFilename: filename) else {
            throw AgentSessionDataError.invalidFilename(filename)
        }
        try requireNoTombstone(for: sessionID)
        let session: AgentSession
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            session = try AgentSessionDataCodec.decodeSession(from: data, using: decoder)
        } catch {
            throw AgentSessionDataError.loadFailed(error)
        }
        let migrationLifecycle: AgentSessionLifecycle? = switch try Self.validateDecodedEnvelope(session) {
        case .legacy:
            .fresh()
        case .v1:
            nil
        }

        do {
            // Gate-held, before normalization: open-turn evidence is stamped in the same value the
            // normalization rewrite commits, so no load sanitizes it away first. Only a cold
            // restoration reads that evidence.
            let interruptionContext: AgentColdRestoreInterruptionContext? = if purpose == .coldRestore {
                await coldRestoreInterruptionContext(sessionID: sessionID)?
                    .withProviderConversationID(session.providerSessionID)
            } else {
                nil
            }
            let normalized = Self.normalizeLoadedSession(
                session,
                fileURL: fileURL,
                purpose: purpose,
                assigningLifecycle: migrationLifecycle,
                interruptionContext: interruptionContext
            )
            var runtimeSession = normalized.runtimeSession
            var persistedSessionToRewrite = normalized.persistedSessionToRewrite
            let reconciledMergeOperations = await AgentSessionWorktreeMergeReconciler.reconcile(runtimeSession.worktreeMergeOperations)
            if reconciledMergeOperations != runtimeSession.worktreeMergeOperations {
                runtimeSession.worktreeMergeOperations = reconciledMergeOperations
                persistedSessionToRewrite = Self.sessionPreparedForStorage(
                    runtimeSession,
                    fileURL: fileURL,
                    savedAt: session.savedAt,
                    preparation: .alreadyCanonicalTranscript,
                    trustedCanonicalItemCount: runtimeSession.itemCount
                )
            }
            let rewrite = try persistedSessionToRewrite.map { persistedSession in
                try LoadedSessionStorageRewrite(
                    persistedSession: persistedSession,
                    encoded: AgentSessionDataCodec.encodeSession(persistedSession, using: encoder)
                )
            }
            try await commitLoadedSessionStorage(rewrite: rewrite, runtimeSession: runtimeSession, fileURL: fileURL)
            noteColdRestoreStamps(
                sessionID: sessionID,
                context: interruptionContext,
                transcript: runtimeSession.transcript
            )
            return runtimeSession
        } catch {
            throw AgentSessionDataError.loadFailed(error)
        }
    }

    /// Whether a best-effort metadata-recovery rewrite may replace this envelope: never for an
    /// unsupported version or unreadable lifecycle.
    private static func permitsMetadataRecoveryRewrite(
        serializationVersion: Int,
        lifecycle: AgentSessionLifecycleMember?
    ) -> Bool {
        guard AgentSession.supportedSerializationVersions.contains(serializationVersion) else { return false }
        if case .unreadable = lifecycle { return false }
        return true
    }

    /// Loads a lightweight stub under the same gate because metadata recovery may rewrite the file.
    func loadAgentSessionStub(
        from fileURL: URL,
        recoverMissingMetadata: Bool = false,
        persistRecoveredMetadata: Bool = false
    ) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard let sessionID = agentSessionID(fromFilename: filename) else {
            throw AgentSessionDataError.invalidFilename(filename)
        }

        await acquireSessionPersistence(for: sessionID)
        do {
            let session = try await loadAgentSessionStubLocked(
                from: fileURL,
                recoverMissingMetadata: recoverMissingMetadata,
                persistRecoveredMetadata: persistRecoveredMetadata
            )
            releaseSessionPersistence(for: sessionID)
            return session
        } catch {
            releaseSessionPersistence(for: sessionID)
            throw error
        }
    }

    private func loadAgentSessionStubLocked(
        from fileURL: URL,
        recoverMissingMetadata: Bool,
        persistRecoveredMetadata: Bool
    ) async throws -> AgentSession {
        let filename = fileURL.lastPathComponent
        guard let sessionID = agentSessionID(fromFilename: filename) else {
            throw AgentSessionDataError.invalidFilename(filename)
        }
        // Inaccessible residue of a committed deletion is never served, even for display.
        try requireNoTombstone(for: sessionID)

        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let decodedHeader = try AgentSessionDataCodec.decodeEnvelope(AgentSessionHeader.self, from: data, using: decoder)
            let header = decodedHeader.value
            // Display-only metadata may be served for any decodable envelope, but a recovery rewrite
            // happens only for a supported envelope; a legacy one gains identity in that rewrite.
            var stubLifecycle = header.lifecycle
            let permitsRewrite = Self.permitsMetadataRecoveryRewrite(
                serializationVersion: header.serializationVersion ?? AgentSession.legacyUnversionedSerializationVersion,
                lifecycle: header.lifecycle
            )
            let migrationLifecycle: AgentSessionLifecycle? = header.lifecycle == nil ? .fresh() : nil
            var recoveredLastUserMessageAt = header.lastUserMessageAt
            var recoveredProjectionCounts = header.transcriptProjectionCounts
            var count = recoveredProjectionCounts?.canonicalVisibleRowCount ?? header.itemCount ?? 0

            if recoverMissingMetadata,
               header.lastUserMessageAt == nil || header.itemCount == nil || header.transcriptProjectionCounts == nil,
               let fullSession = try? AgentSessionDataCodec.decodeSession(from: data, using: decoder)
            {
                // Metadata recovery is a storage mutation: it never stamps or sanitizes (F-7).
                let normalized = Self.normalizeLoadedSession(
                    fullSession,
                    fileURL: fileURL,
                    purpose: .storageMutation,
                    assigningLifecycle: migrationLifecycle
                )
                if let transcript = normalized.runtimeSession.transcript {
                    recoveredLastUserMessageAt = recoveredLastUserMessageAt ?? Self.computeLastUserMessageAt(in: transcript)
                    let projectionCounts = Self.computeProjectionCounts(in: transcript)
                    recoveredProjectionCounts = recoveredProjectionCounts ?? projectionCounts
                    if header.itemCount == nil {
                        count = projectionCounts.canonicalVisibleRowCount
                    }
                } else {
                    recoveredLastUserMessageAt = recoveredLastUserMessageAt ?? Self.computeLastUserMessageAt(in: normalized.runtimeSession.items)
                    recoveredProjectionCounts = recoveredProjectionCounts ?? .init(
                        canonicalVisibleRowCount: normalized.runtimeSession.items.count,
                        defaultPresentedRowCount: normalized.runtimeSession.items.count
                    )
                    if header.itemCount == nil {
                        count = normalized.runtimeSession.items.count
                    }
                }
                count = recoveredProjectionCounts?.canonicalVisibleRowCount ?? count
                if persistRecoveredMetadata,
                   permitsRewrite,
                   let persistedSession = normalized.persistedSessionToRewrite
                {
                    do {
                        let encoded = try AgentSessionDataCodec.encodeSession(persistedSession, using: encoder)
                        try await writeDataAtomically(encoded, to: fileURL)
                        // Only a committed rewrite makes migration identity durable.
                        stubLifecycle = persistedSession.lifecycle
                        rememberLifecycle(of: persistedSession, fileURL: fileURL)
                        await upsertMetadataRecord(
                            metadataRecord(from: persistedSession, fileURL: fileURL),
                            folder: fileURL.deletingLastPathComponent()
                        )
                    } catch {
                        // Best-effort migration only; continue serving recovered values in-memory.
                    }
                }
            }
            let stub = AgentSession(
                id: header.id,
                serializationVersion: header.serializationVersion ?? AgentSession.legacyUnversionedSerializationVersion,
                workspaceID: header.workspaceID,
                composeTabID: header.composeTabID,
                name: header.name,
                savedAt: header.savedAt,
                fileURL: fileURL,
                items: [],
                transcript: nil,
                itemCount: count,
                transcriptProjectionCounts: recoveredProjectionCounts,
                lastUserMessageAt: recoveredLastUserMessageAt,
                agentKind: header.agentKind,
                agentModel: header.agentModel,
                ohMyPiThinkingSelections: header.ohMyPiThinkingSelections,
                agentReasoningEffort: header.agentReasoningEffort,
                lastRunState: AgentSessionRestoreSupport.coldRestoredLastRunStateRaw(header.lastRunState),
                providerSessionID: header.providerSessionID,
                remoteHost: header.remoteHost,
                autoEditEnabled: header.autoEditEnabled,
                providerUsage: decodedHeader.providerUsage,
                codexConversationID: header.codexConversationID,
                codexRolloutPath: header.codexRolloutPath,
                codexModel: header.codexModel,
                codexReasoningEffort: header.codexReasoningEffort,
                codexContextWindow: header.codexContextWindow,
                codexLastTotalTokens: header.codexLastTotalTokens,
                codexTotalTotalTokens: header.codexTotalTotalTokens,
                codexMcpSessionKey: header.codexMcpSessionKey,
                parentSessionID: header.parentSessionID,
                pendingHandoffPayload: header.pendingHandoffPayload,
                pendingHandoffCreatedAt: header.pendingHandoffCreatedAt,
                pendingHandoffSourceItemID: header.pendingHandoffSourceItemID,
                pendingHandoffPayloadID: header.pendingHandoffPayloadID,
                pendingHandoffDefersProviderLockUntilSend: header.pendingHandoffDefersProviderLockUntilSend ?? false,
                scheduledSend: header.scheduledSend,
                lastScheduledDispatch: header.lastScheduledDispatch,
                isMCPOriginated: header.isMCPOriginated ?? false,
                origin: header.origin,
                profile: header.profile ?? .standard,
                worktreeBindings: header.worktreeBindings ?? [],
                worktreeMergeOperations: header.worktreeMergeOperations ?? [],
                lifecycle: stubLifecycle
            )
            rememberScheduleAuthority(from: stub, fileURL: fileURL)
            return stub
        } catch {
            throw AgentSessionDataError.loadFailed(error)
        }
    }

    /// Returns a list of AgentSession files in the workspace's AgentSessions folder, sorted by mod date desc.
    func listAgentSessions(for workspace: some AgentWorkspaceStorageReference) async throws -> [URL] {
        guard let agentSessionsFolder = agentSessionsFolderIfExists(for: workspace) else { return [] }

        let contents = try FileManager.default.contentsOfDirectory(
            at: agentSessionsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let tombstoned = try tombstonedSessionIDs()
        let jsonFiles = contents.filter { fileURL in
            agentSessionID(fromFilename: fileURL.lastPathComponent).map {
                !isTombstonedResidue(fileURL, sessionID: $0, tombstoned: tombstoned)
            } ?? false
        }

        let datedFiles = jsonFiles.map { url in
            let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (url: url, modificationDate: modificationDate)
        }
        return datedFiles.sorted { lhs, rhs in
            lhs.modificationDate > rhs.modificationDate
        }.map(\.url)
    }

    /// Get metadata for recent agent sessions without loading full content.
    func recentSessions(for workspace: some AgentWorkspaceStorageReference, limit: Int = 10) async throws -> [AgentSessionMeta] {
        do {
            return try await metadataRecords(for: workspace, limit: limit).map {
                $0.agentSessionMeta()
            }
        } catch {
            let files = try await listAgentSessions(for: workspace)
            var metadataList: [AgentSessionMeta] = []

            for fileURL in files.prefix(max(limit, 0)) {
                do {
                    let session = try await loadAgentSessionStub(from: fileURL, recoverMissingMetadata: false)
                    let lastModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? session.savedAt

                    let meta = AgentSessionMeta(
                        id: session.id,
                        composeTabID: session.composeTabID,
                        name: session.name,
                        lastModified: lastModified,
                        itemCount: session.effectiveItemCount,
                        agentKind: session.agentKind,
                        agentModel: session.agentModel,
                        lastRunState: session.lastRunState,
                        parentSessionID: session.parentSessionID,
                        remoteHostID: session.remoteHost?.hostID,
                        remoteHostName: session.remoteHost?.hostDisplayName,
                        remoteSessionID: session.remoteHost?.normalizedRemoteSessionID,
                        isMCPOriginated: session.isMCPOriginated,
                        origin: session.origin,
                        worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                        activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
                    )
                    metadataList.append(meta)
                } catch {
                    continue
                }
            }

            return metadataList
        }
    }

    /// Get lightweight metadata for agent sessions without loading full transcript content.
    package func listAgentSessionsMeta(
        for workspace: some AgentWorkspaceStorageReference,
        limit: Int? = nil
    ) async throws -> [AgentSessionMeta] {
        do {
            return try await metadataRecords(for: workspace, limit: limit).map {
                $0.agentSessionMeta()
            }
        } catch {
            let files = try await listAgentSessions(for: workspace)
            let boundedFiles: ArraySlice<URL> = if let limit {
                files.prefix(max(limit, 0))
            } else {
                files[...]
            }

            var metadataList: [AgentSessionMeta] = []
            metadataList.reserveCapacity(boundedFiles.count)

            for fileURL in boundedFiles {
                do {
                    let session = try await loadAgentSessionStub(
                        from: fileURL,
                        recoverMissingMetadata: false,
                        persistRecoveredMetadata: false
                    )
                    let lastModified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        ?? session.savedAt
                    metadataList.append(
                        AgentSessionMeta(
                            id: session.id,
                            composeTabID: session.composeTabID,
                            name: session.name,
                            lastModified: lastModified,
                            itemCount: session.effectiveItemCount,
                            agentKind: session.agentKind,
                            agentModel: session.agentModel,
                            lastRunState: session.lastRunState,
                            parentSessionID: session.parentSessionID,
                            remoteHostID: session.remoteHost?.hostID,
                            remoteHostName: session.remoteHost?.hostDisplayName,
                            remoteSessionID: session.remoteHost?.normalizedRemoteSessionID,
                            isMCPOriginated: session.isMCPOriginated,
                            origin: session.origin,
                            worktreeBindingSummaries: session.worktreeBindings.worktreeBindingSummaries,
                            activeWorktreeMergeSummaries: session.worktreeMergeOperations.activeWorktreeMergeSummaries
                        )
                    )
                } catch {
                    continue
                }
            }

            return metadataList
        }
    }

    /// Resolves a session reference (UUID string only) to a session ID.
    package func resolveAgentSessionID(
        reference: String,
        for workspace: some AgentWorkspaceStorageReference
    ) async throws -> UUID? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let uuid = UUID(uuidString: trimmed) else { return nil }
        return try await loadAgentSession(id: uuid, for: workspace) != nil ? uuid : nil
    }

    package func loadAgentSession(
        reference: String,
        for workspace: some AgentWorkspaceStorageReference
    ) async throws -> AgentSession? {
        guard let sessionID = try await resolveAgentSessionID(reference: reference, for: workspace) else {
            return nil
        }
        return try await loadAgentSession(id: sessionID, for: workspace)
    }

    /// Find an agent session by its ID for a workspace.
    func findAgentSession(id: UUID, for workspace: some AgentWorkspaceStorageReference) async throws -> AgentSession? {
        let files = try await listAgentSessions(for: workspace)

        for fileURL in files {
            let filename = fileURL.lastPathComponent
            if filename == "AgentSession-\(id.uuidString).json" {
                return try await loadAgentSession(from: fileURL)
            }
        }

        return nil
    }

    /// Load an agent session by ID without scanning the session directory.
    package func loadAgentSession(id: UUID, for workspace: some AgentWorkspaceStorageReference) async throws -> AgentSession? {
        let agentSessionsFolder = agentSessionsFolderURL(for: workspace)
        let filename = "AgentSession-\(id.uuidString).json"
        let fileURL = agentSessionsFolder.appendingPathComponent(filename)

        // A logically deleted session is absent even when unlink left residue behind.
        guard try tombstoneState(for: id) == .absent,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            return nil
        }

        return try await loadAgentSession(from: fileURL)
    }

    /// Find an agent session by compose tab ID.
    func findAgentSessionForTab(_ tabID: UUID, for workspace: some AgentWorkspaceStorageReference) async throws -> AgentSession? {
        if let records = try? await metadataRecords(for: workspace),
           let best = records
           .filter({ $0.composeTabID == tabID })
           .sortedForAgentSessionMetadataIndex()
           .first
        {
            if let session = try await loadAgentSession(id: best.id, for: workspace) {
                return session
            }
            let folder = agentSessionsFolderURL(for: workspace)
            await removeMetadataRecords(matching: { $0.id == best.id }, folder: folder)
        }

        let files = try await listAgentSessions(for: workspace)

        for fileURL in files {
            do {
                let stub = try await loadAgentSessionStub(from: fileURL, recoverMissingMetadata: false)
                if stub.composeTabID == tabID {
                    return try await loadAgentSession(from: fileURL)
                }
            } catch {
                continue
            }
        }

        return nil
    }

    /// Delete a particular agent session file under the same per-session gate as saves and CAS.
    /// A filename that is not a session UUID is rejected (no ungated fallback).
    func deleteAgentSessionFile(_ fileURL: URL) async throws {
        guard let sessionID = agentSessionID(fromFilename: fileURL.lastPathComponent) else {
            throw AgentSessionDataError.invalidFilename(fileURL.lastPathComponent)
        }
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        try await deleteAgentSessionFileLocked(fileURL, sessionID: sessionID)
    }

    /// Tombstone-first deletion (callers hold the gate). The durable tombstone is the commit point:
    /// its write failure throws with nothing published or unlinked. After it, deletion is logically
    /// effective (caches, live authority, notification), and an unlink failure only leaves
    /// inaccessible residue that is reported diagnostically; repeated deletion retries cleanup
    /// without publishing the logical deletion again (one generation bump and notification per
    /// tombstone commit).
    private func deleteAgentSessionFileLocked(
        _ fileURL: URL, sessionID: UUID, holdingRichFilesystemFence: Bool = false,
        currentWorkspaceRoot: URL? = nil
    ) async throws {
        let folder = fileURL.deletingLastPathComponent()
        let filename = fileURL.lastPathComponent
        let fileKey = canonicalSessionFileKey(fileURL)
        let newlyCommitted = try commitTombstone(for: sessionID)

        // Caches never describe a deleted file (idempotent on retry).
        scheduleAuthorityByFileURL.removeValue(forKey: fileKey)
        transcriptResetAuthorityByFileURL.removeValue(forKey: fileKey)
        lifecycleByFileKey.removeValue(forKey: fileKey)
        if newlyCommitted {
            // Publish logical deletion synchronously under the per-session gate, exactly once.
            let generation = (deletionGenerationsByFileKey[fileKey] ?? 0) &+ 1
            deletionGenerationsByFileKey[fileKey] = generation
            let userInfo: [String: Any] = ["fileKey": fileKey, "generation": generation, "sessionID": sessionID]
            NotificationCenter.default.post(name: .agentSessionDeletionDidCommit, object: nil, userInfo: userInfo)
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                #if DEBUG
                    if let injected = test_agentSessionDeletionFailureInjector?(fileURL) {
                        throw injected
                    }
                #endif
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                print("[AgentSessionDataService] deletion committed for \(sessionID); session file cleanup failed and residue remains inaccessible: \(error)")
            }
        }
        // Rich tree beside AgentSessions: the root of the session-file location this deletion used
        // and, when the caller resolved it, the workspace's current root (a stamp URL captured
        // before a completed move or rename is stale). The tombstone above already committed this
        // session's deletion, so either location holds only this session's residue. Each root is
        // resolved once (the store refuses a symlinked root). Fence after the session gate (global
        // lock order).
        var richRoots: [URL] = []
        for candidate in [folder.deletingLastPathComponent(), currentWorkspaceRoot].compactMap(\.self) {
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            if !richRoots.contains(resolved) { richRoots.append(resolved) }
        }
        let richFence = AgentRichArtifactFilesystemFence.shared
        if !holdingRichFilesystemFence { await richFence.acquire() }
        for root in richRoots {
            do {
                #if DEBUG
                    if let injected = test_richArtifactDeletionFailure?(sessionID) { throw injected }
                #endif
                try await AgentRichArtifactStore.offMain {
                    try AgentRichArtifactStore.removeSession(root: root, sessionID: sessionID)
                }
            } catch {
                print("[AgentSessionDataService] deletion committed for \(sessionID); rich cleanup failed and residue remains inaccessible: \(error)")
            }
        }
        if !holdingRichFilesystemFence { richFence.release() }
        if let recoveryStore {
            // Still under the session gate: no recovery transaction can interleave. Failure never
            // reverses the deletion; tombstone filtering hides any residue and a repeated
            // deletion retries the cleanup.
            do {
                _ = try await recoveryStore.removeDataForDeletedSession(sessionID: sessionID)
            } catch {
                print("[AgentSessionDataService] deletion committed for \(sessionID); recovery cleanup failed and residue remains nonactionable: \(error)")
            }
        }
        await removeMetadataRecords(
            matching: { record in
                record.filename == filename || record.id == sessionID
            },
            folder: folder
        )
    }

    /// Current explicit-deletion generation for a session file (0 when never deleted).
    func scheduledSendDeletionGeneration(for fileURL: URL) -> UInt64 {
        deletionGenerationsByFileKey[canonicalSessionFileKey(fileURL)] ?? 0
    }

    /// Delete an agent session by ID under the same per-session gate as saves and CAS.
    package func deleteAgentSession(id: UUID, for workspace: some AgentWorkspaceStorageReference) async throws {
        let agentSessionsFolder = try ensureAgentSessionsFolder(for: workspace)
        let fileURL = agentSessionsFolder.appendingPathComponent(agentSessionFilename(for: id))
        try await deleteAgentSessionFile(fileURL)
    }

    package func deletionCandidates(
        forComposeTabID tabID: UUID,
        for workspace: some AgentWorkspaceStorageReference
    ) async throws -> [AgentSessionDeletionCandidate] {
        guard let agentSessionsFolder = agentSessionsFolderIfExists(for: workspace) else { return [] }
        var candidateFilesByPath: [String: URL] = [:]
        if let index = await readMetadataIndexIfAvailable(folder: agentSessionsFolder) {
            for record in index.entries where record.composeTabID == tabID {
                let fileURL = agentSessionsFolder.appendingPathComponent(record.filename)
                candidateFilesByPath[fileURL.path] = fileURL
            }
        }

        let files = try await listAgentSessions(for: workspace)
        var incarnationByPath: [String: UUID] = [:]
        for fileURL in files {
            guard
                let stub = try? await loadAgentSessionStub(
                    from: fileURL,
                    recoverMissingMetadata: false,
                    persistRecoveredMetadata: false
                ),
                stub.composeTabID == tabID
            else { continue }
            candidateFilesByPath[fileURL.path] = fileURL
            incarnationByPath[fileURL.path] = stub.lifecycle?.lifecycle?.incarnationID
        }

        let tombstoned = try tombstonedSessionIDs()
        return candidateFilesByPath.compactMap { path, fileURL in
            guard let sessionID = agentSessionID(fromFilename: fileURL.lastPathComponent),
                  !tombstoned.contains(sessionID)
            else {
                return nil
            }
            let fileKey = canonicalSessionFileKey(fileURL)
            let incarnationID = incarnationByPath[path]
            return AgentSessionDeletionCandidate(
                composeTabID: tabID,
                persistenceState: AgentSessionPersistenceState(
                    stamp: AgentSessionPersistenceStamp(
                        sessionID: sessionID,
                        workspaceID: workspace.id,
                        deletionGeneration: deletionGenerationsByFileKey[fileKey] ?? 0,
                        incarnationID: incarnationID,
                        serviceID: persistenceServiceID,
                        fileURL: fileKey
                    ),
                    transcriptResetGeneration: lifecycleByFileKey[fileKey].flatMap {
                        $0.incarnationID == incarnationID ? $0.transcriptResetGeneration : nil
                    } ?? 0
                )
            )
        }
    }

    package func deleteAgentSession(
        ifCurrent candidate: AgentSessionDeletionCandidate,
        for workspace: some AgentWorkspaceStorageReference
    ) async throws -> AgentSessionConditionalDeletionResult {
        let state = candidate.persistenceState
        let sessionID = state.stamp.sessionID
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        #if DEBUG
            if let testConditionalDeletionHook {
                try await testConditionalDeletionHook(candidate)
            }
        #endif
        try validatePersistenceStamp(
            state.stamp,
            sessionID: sessionID,
            workspaceID: workspace.id
        )
        let fileURL = state.stamp.fileURL
        let currentRoot = workspaceFolderURL(for: workspace)
        switch try tombstoneState(for: sessionID) {
        case .absent:
            break
        case .committed:
            // Already logically deleted: retry cleanup of any residue.
            try await deleteAgentSessionFileLocked(fileURL, sessionID: sessionID, currentWorkspaceRoot: currentRoot)
            return .alreadyAbsent
        case .unreadable:
            throw AgentScheduledSendMutationError.unreadableTombstone(sessionID)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try await deleteAgentSessionFileLocked(fileURL, sessionID: sessionID, currentWorkspaceRoot: currentRoot)
            return .alreadyAbsent
        }
        guard
            let stub = try? await loadAgentSessionStubLocked(
                from: fileURL,
                recoverMissingMetadata: false,
                persistRecoveredMetadata: false
            ),
            stub.id == sessionID,
            stub.composeTabID == candidate.composeTabID,
            state.stamp.incarnationID == nil
            || state.stamp.incarnationID == stub.lifecycle?.lifecycle?.incarnationID
        else {
            return .ownershipChanged
        }
        try await deleteAgentSessionFileLocked(fileURL, sessionID: sessionID, currentWorkspaceRoot: currentRoot)
        return .deleted
    }

    func deleteAgentSessions(forComposeTabID tabID: UUID, for workspace: some AgentWorkspaceStorageReference) async throws {
        // No folder means no session files and no index for this tab.
        guard let agentSessionsFolder = agentSessionsFolderIfExists(for: workspace) else { return }
        var candidateFilesByPath: [String: URL] = [:]
        if let index = await readMetadataIndexIfAvailable(folder: agentSessionsFolder) {
            for record in index.entries where record.composeTabID == tabID {
                candidateFilesByPath[agentSessionsFolder.appendingPathComponent(record.filename).path] = agentSessionsFolder.appendingPathComponent(record.filename)
            }
        }

        let files = try await listAgentSessions(for: workspace)
        for fileURL in files {
            guard
                let stub = try? await loadAgentSessionStub(
                    from: fileURL,
                    recoverMissingMetadata: false,
                    persistRecoveredMetadata: false
                ),
                stub.composeTabID == tabID
            else { continue }
            candidateFilesByPath[fileURL.path] = fileURL
        }

        for fileURL in candidateFilesByPath.values {
            try? await deleteAgentSessionFile(fileURL)
        }
        await removeMetadataRecords(matching: { $0.composeTabID == tabID }, folder: agentSessionsFolder)
    }

    #if DEBUG
        func test_clearMetadataIndexCache(forAgentSessionsFolder folder: URL) {
            let key = canonicalMetadataFolderKey(folder)
            metadataIndexCacheByFolder.removeValue(forKey: key)
            metadataIndexReconciliationTasksByFolder[key]?.task.cancel()
            metadataIndexReconciliationTasksByFolder.removeValue(forKey: key)
            metadataIndexReconciledThisProcess.remove(key)
        }

        func test_markMetadataIndexReconciledThisProcess(forAgentSessionsFolder folder: URL) {
            metadataIndexReconciledThisProcess.insert(canonicalMetadataFolderKey(folder))
        }

        func test_cachedMetadataIndexEntryCount(forAgentSessionsFolder folder: URL) -> Int? {
            metadataIndexCacheByFolder[canonicalMetadataFolderKey(folder)]?.entries.count
        }

        func test_isMetadataIndexReconciliationScheduled(forAgentSessionsFolder folder: URL) -> Bool {
            metadataIndexReconciliationTasksByFolder[canonicalMetadataFolderKey(folder)] != nil
        }
    #endif

    // MARK: - Worktree merge review retention (Step 5c)

    /// The established AgentSessions folder of a captured editable persistence authority: the
    /// stamp must be this service's, not deleted, not tombstoned, and still the file's durable
    /// incarnation. No mutable workspace resolver is consulted; the caller derives its
    /// operation-owned subdirectory from the returned folder.
    package func worktreeMergeReviewRetentionParent(for state: AgentSessionPersistenceState) async throws -> URL {
        let stamp = state.stamp
        await acquireSessionPersistence(for: stamp.sessionID)
        defer { releaseSessionPersistence(for: stamp.sessionID) }
        try validatePersistenceStamp(stamp, sessionID: stamp.sessionID, workspaceID: stamp.workspaceID)
        try requireNoTombstone(for: stamp.sessionID)
        guard FileManager.default.fileExists(atPath: stamp.fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionNotFound(stamp.sessionID)
        }
        guard case let .v1(current) = try currentDurableLifecycle(fileURL: stamp.fileURL, sessionID: stamp.sessionID),
              let expected = stamp.incarnationID,
              current.incarnationID == expected
        else {
            throw AgentScheduledSendMutationError.staleIncarnation(expected: stamp.incarnationID, actual: nil)
        }
        return stamp.fileURL.deletingLastPathComponent()
    }

    // MARK: - Rich artifacts (the existing session gates are the only lifetime authority)

    #if DEBUG
        private var test_richArtifactPhase: (@Sendable (String, UUID) async throws -> Void)?
        private var test_richArtifactDeletionFailure: (@Sendable (UUID) -> Error?)?
        package func test_setRichArtifactPhase(_ hook: (@Sendable (String, UUID) async throws -> Void)?) {
            test_richArtifactPhase = hook
        }

        package func test_setRichArtifactDeletionFailure(_ hook: (@Sendable (UUID) -> Error?)?) {
            test_richArtifactDeletionFailure = hook
        }

        package func test_richSessionWaiterCount(_ sessionID: UUID) -> Int {
            sessionPersistenceWaiters[sessionID]?.count ?? 0
        }
    #endif

    /// Rich authority for a session under `root` (a root its caller validated as the workspace's
    /// current storage). Stamps are never refreshed, so the stamp's absolute path can predate a
    /// completed rename or storage move; identity is therefore this session's own file under
    /// `root` plus the stamp's durable incarnation there (with the stamp's service, deletion
    /// generation and the authoritative tombstone), not the stamp's absolute directory.
    private func validateRichAuthority(
        _ state: AgentSessionPersistenceState, root: URL
    ) throws {
        let stamp = state.stamp
        try validatePersistenceStamp(stamp, sessionID: stamp.sessionID, workspaceID: stamp.workspaceID)
        try requireNoTombstone(for: stamp.sessionID)
        let fileURL = agentSessionFileURL(
            id: stamp.sessionID, in: root.appendingPathComponent(Self.agentSessionsFolderName)
        )
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw AgentRichArtifactError.storageMoved }
        guard case let .v1(current) = try currentDurableLifecycle(fileURL: fileURL, sessionID: stamp.sessionID),
              let expected = stamp.incarnationID, current.incarnationID == expected
        else { throw AgentScheduledSendMutationError.staleIncarnation(expected: stamp.incarnationID, actual: nil) }
    }

    /// Creation-only predicate (on top of `validateRichAuthority`): the stamp's own session file
    /// must be this session's file under `root`. A stamp that predates a completed rename or move
    /// is refused for creation (no stamp refresh or persistence unification); history and handoff
    /// keep reading the same incarnation at the moved root.
    private func validateRichCreationStamp(_ state: AgentSessionPersistenceState, root: URL) throws {
        let expected = agentSessionFileURL(
            id: state.stamp.sessionID, in: root.appendingPathComponent(Self.agentSessionsFolderName)
        )
        guard state.stamp.fileURL.standardizedFileURL.resolvingSymlinksInPath()
            == expected.standardizedFileURL.resolvingSymlinksInPath()
        else { throw AgentRichArtifactError.staleSessionStamp }
    }

    package func captureRichArtifactRoot(
        state: AgentSessionPersistenceState, workspace: some AgentWorkspaceStorageReference,
        resolvedRoot: URL
    ) async throws -> URL {
        await acquireSessionPersistence(for: state.stamp.sessionID)
        defer { releaseSessionPersistence(for: state.stamp.sessionID) }
        guard workspace.id == state.stamp.workspaceID,
              workspaceFolderURL(for: workspace).standardizedFileURL.resolvingSymlinksInPath() == resolvedRoot.standardizedFileURL.resolvingSymlinksInPath()
        else { throw AgentRichArtifactError.storageMoved }
        try validateRichAuthority(state, root: resolvedRoot)
        try validateRichCreationStamp(state, root: resolvedRoot)
        return resolvedRoot
    }

    package func publishRichArtifact(
        state: AgentSessionPersistenceState, root: URL,
        manifest: AgentRichArtifactManifest, assets: [UUID: Data],
        commitCheck: @escaping @MainActor () throws -> Void
    ) async throws {
        let sessionID = state.stamp.sessionID
        await acquireSessionPersistence(for: sessionID)
        defer { releaseSessionPersistence(for: sessionID) }
        let fence = AgentRichArtifactFilesystemFence.shared
        await fence.acquire()
        defer { fence.release() }
        try Task.checkCancellation()
        try validateRichAuthority(state, root: root)
        try validateRichCreationStamp(state, root: root)
        guard manifest.provenance.sessionID == sessionID else { throw AgentRichArtifactError.invalidManifest }
        #if DEBUG
            try await test_richArtifactPhase?("beforeStage", sessionID)
        #endif
        let stage = try await AgentRichArtifactStore.cancellable { cancellation in
            try AgentRichArtifactStore.stage(root: root, sessionID: sessionID, manifest: manifest, assets: assets, cancellation: cancellation)
        }
        do {
            #if DEBUG
                try await test_richArtifactPhase?("afterStage", sessionID)
            #endif
            try Task.checkCancellation()
            try validateRichAuthority(state, root: root)
            try validateRichCreationStamp(state, root: root)
            // The final exact-attempt/root check and the single rename cannot interleave with a
            // root mutation request. Bulk bytes have already been written off-main.
            try await MainActor.run {
                try commitCheck()
                try AgentRichArtifactStore.install(stage)
            }
        } catch {
            _ = try? await AgentRichArtifactStore.offMain { AgentRichArtifactStore.discard(stage) }
            throw error
        }
        // Rename committed: no post-commit cancellation error or automatic retry.
    }

    #if DEBUG
        /// Test-only strict read (manifest plus every asset) at a caller-supplied root. Production
        /// history never passes a root: it uses `captureRichArtifactReadCapability` and the
        /// capability reads below.
        package func readRichArtifact(
            state: AgentSessionPersistenceState, root: URL, reference: RichPresentationReference
        ) async throws -> AgentRichArtifactManifest {
            await acquireSessionPersistence(for: state.stamp.sessionID)
            defer { releaseSessionPersistence(for: state.stamp.sessionID) }
            let fence = AgentRichArtifactFilesystemFence.shared
            await fence.acquire()
            defer { fence.release() }
            try validateRichAuthority(state, root: root)
            return try await AgentRichArtifactStore.offMain {
                try AgentRichArtifactStore.read(root: root, sessionID: state.stamp.sessionID, reference: reference)
            }
        }
    #endif

    // MARK: Historical reads

    /// A trusted current storage directory for one workspace, resolved by the App from its exact
    /// workspace model (the workspace manager's ACTUAL current directory, not this service's root
    /// and not the D2 agreement: history renders even where creation is refused) together with the
    /// App's storage revision at resolution.
    // swiftformat:disable:next redundantSendable
    package struct ResolvedRichHistoryStorage: Hashable, Sendable {
        package let workspaceID: UUID
        package let directory: URL
        package let revision: UInt64

        package init(workspaceID: UUID, directory: URL, revision: UInt64) {
            self.workspaceID = workspaceID
            self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
            self.revision = revision
        }
    }

    /// Read authority for one exact hydrated session at one resolved storage directory. Opaque to
    /// callers: it can only be minted by `captureRichArtifactReadCapability`.
    // swiftformat:disable:next redundantSendable
    package struct RichArtifactReadCapability: Hashable, Sendable {
        package let sessionID: UUID
        package let storage: ResolvedRichHistoryStorage
        fileprivate let incarnationID: UUID
    }

    /// Captures read authority for the exact hydrated owner `state` at `resolvedStorage`: the
    /// stamp's service and deletion generation, no tombstone, this session's own file under that
    /// directory, and the stamp's durable incarnation there. The stamp is never refreshed and its
    /// absolute path may predate a completed move. `checkCurrentContext` runs on the main actor
    /// under the gates and must throw unless the owner and storage are still current.
    package func captureRichArtifactReadCapability(
        state: AgentSessionPersistenceState,
        resolvedStorage: ResolvedRichHistoryStorage,
        checkCurrentContext: @escaping @MainActor () throws -> Void
    ) async throws -> RichArtifactReadCapability {
        let stamp = state.stamp
        guard stamp.workspaceID == resolvedStorage.workspaceID else { throw AgentRichArtifactError.storageMoved }
        await acquireSessionPersistence(for: stamp.sessionID)
        defer { releaseSessionPersistence(for: stamp.sessionID) }
        try validateRichAuthority(state, root: resolvedStorage.directory)
        guard let incarnationID = stamp.incarnationID else {
            throw AgentScheduledSendMutationError.staleIncarnation(expected: nil, actual: nil)
        }
        try await MainActor.run { try checkCurrentContext() }
        return RichArtifactReadCapability(sessionID: stamp.sessionID, storage: resolvedStorage, incarnationID: incarnationID)
    }

    /// Re-validates a capability under the session gate and the filesystem fence (so no root move
    /// interleaves), then runs `read` off-main.
    private func withRichReadCapability<T: Sendable>(
        _ capability: RichArtifactReadCapability,
        checkCurrentStorage: @escaping @MainActor () throws -> Void,
        read: @escaping @Sendable (URL) throws -> T
    ) async throws -> T {
        await acquireSessionPersistence(for: capability.sessionID)
        defer { releaseSessionPersistence(for: capability.sessionID) }
        let fence = AgentRichArtifactFilesystemFence.shared
        await fence.acquire()
        defer { fence.release() }
        try Task.checkCancellation()
        try requireNoTombstone(for: capability.sessionID)
        let root = capability.storage.directory
        let fileURL = agentSessionFileURL(
            id: capability.sessionID, in: root.appendingPathComponent(Self.agentSessionsFolderName)
        )
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw AgentRichArtifactError.storageMoved }
        guard case let .v1(current) = try currentDurableLifecycle(fileURL: fileURL, sessionID: capability.sessionID),
              current.incarnationID == capability.incarnationID
        else {
            throw AgentScheduledSendMutationError.staleIncarnation(expected: capability.incarnationID, actual: nil)
        }
        try await MainActor.run { try checkCurrentStorage() }
        return try await AgentRichArtifactStore.offMain { try read(root) }
    }

    /// The validated manifest of `reference` (assets are not read). A missing or invalid manifest
    /// throws; the renderer then shows the reference's labeled fallback.
    package func readRichArtifactManifest(
        capability: RichArtifactReadCapability,
        reference: RichPresentationReference,
        checkCurrentStorage: @escaping @MainActor () throws -> Void
    ) async throws -> AgentRichArtifactManifest {
        let sessionID = capability.sessionID
        return try await withRichReadCapability(capability, checkCurrentStorage: checkCurrentStorage) { root in
            try AgentRichArtifactStore.readManifest(root: root, sessionID: sessionID, reference: reference)
        }
    }

    /// The validated JPEG bytes of one asset of `manifest`. A missing or invalid asset throws; the
    /// renderer then shows that image's placeholder and keeps the rest of the document.
    package func readRichArtifactAsset(
        capability: RichArtifactReadCapability,
        manifest: AgentRichArtifactManifest,
        assetID: UUID,
        checkCurrentStorage: @escaping @MainActor () throws -> Void
    ) async throws -> Data {
        let sessionID = capability.sessionID
        return try await withRichReadCapability(capability, checkCurrentStorage: checkCurrentStorage) { root in
            try AgentRichArtifactStore.readAsset(root: root, sessionID: sessionID, manifest: manifest, assetID: assetID)
        }
    }

    /// Private handoff commit. The destination session gate (and, when artifacts must be copied,
    /// the source gate in UUID order), then the rich filesystem fence, stay held through copying,
    /// the exclusive initial save, the final main-actor check and exposure, or rollback. Every
    /// handoff, with or without references, protects destination storage identity: `root` must be
    /// this service's root for `workspace` (`workspaceStorageRoot(for:)`). That internal check only
    /// compares two values derived from the caller's `workspace` snapshot; the caller's
    /// `commitCheck` is the ONLY check against the current workspace and its storage (revision and
    /// root), so a caller that passes a no-op check gets no current-root protection. Root mutations wait for
    /// the fence before moving anything, so no physical move can interleave between the checks
    /// and the save or exposure, and a stale root never recreates an old directory. With no
    /// references no source authority is needed and nothing is copied.
    /// Rollback never exposes the destination: private records are discarded, a committed
    /// destination file goes through the existing tombstone-first deletion, and destination rich
    /// residue is removed. The source is never mutated.
    package func commitPrivateHandoff(
        sourceState: AgentSessionPersistenceState?, initialSession: AgentSession,
        workspace: some AgentWorkspaceStorageReference, root: URL,
        references: [RichPresentationReference],
        persistPrivateRecords: @escaping @MainActor () async throws -> Void = {},
        discardPrivateRecords: @escaping @MainActor () async -> Void = {},
        commitCheck: @escaping @MainActor () throws -> Void,
        expose: @escaping @MainActor (AgentSessionEditableLoad) throws -> Void
    ) async throws {
        // `commitCheck` runs before the first copy, before each copy, before the initial save and
        // in the main-actor exposure section, all under the session gates and the fence.
        let destinationID = initialSession.id
        guard initialSession.lifecycle == nil, initialSession.workspaceID == workspace.id,
              !(initialSession.isListStub && initialSession.effectiveItemCount > 0)
        else { throw AgentScheduledSendMutationError.invalidInitialSession(destinationID) }
        var unique = Set<UUID>()
        let copies = references.filter { unique.insert($0.artifactID).inserted }
        var copy: (source: AgentSessionPersistenceState, root: URL)?
        if !copies.isEmpty {
            guard let sourceState, sourceState.stamp.sessionID != destinationID,
                  sourceState.stamp.workspaceID == workspace.id
            else { throw AgentRichArtifactError.sourceUnavailable }
            copy = (sourceState, root)
        }
        let ids = ([destinationID] + (copy.map { [$0.source.stamp.sessionID] } ?? []))
            .sorted { $0.uuidString < $1.uuidString }
        for id in ids {
            await acquireSessionPersistence(for: id)
        }
        defer { for id in ids.reversed() {
            releaseSessionPersistence(for: id)
        } }
        let fence = AgentRichArtifactFilesystemFence.shared
        await fence.acquire()
        defer { fence.release() }

        try Task.checkCancellation()
        guard workspaceFolderURL(for: workspace).standardizedFileURL.resolvingSymlinksInPath()
            == root.standardizedFileURL.resolvingSymlinksInPath()
        else { throw AgentRichArtifactError.storageMoved }
        if let copy {
            try validateRichAuthority(copy.source, root: copy.root)
        }
        try requireNoTombstone(for: destinationID)
        let fileURL = agentSessionFileURL(id: destinationID, in: agentSessionsFolderURL(for: workspace))
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentScheduledSendMutationError.sessionAlreadyExists(destinationID)
        }
        do {
            try await commitCheck()
            if let copy {
                let sourceID = copy.source.stamp.sessionID
                for reference in copies {
                    try Task.checkCancellation()
                    try await commitCheck()
                    #if DEBUG
                        try await test_richArtifactPhase?("beforeCopy", reference.artifactID)
                    #endif
                    try await AgentRichArtifactStore.cancellable { cancellation in
                        try AgentRichArtifactStore.copy(
                            root: copy.root, source: sourceID, destination: destinationID,
                            reference: reference, cancellation: cancellation
                        )
                    }
                }
                try Task.checkCancellation()
                // The source gate is still held: no deletion or new incarnation can have committed.
                try validateRichAuthority(copy.source, root: copy.root)
            }
            #if DEBUG
                try await test_richArtifactPhase?("afterCopy", destinationID)
            #endif
            try await persistPrivateRecords()
            try Task.checkCancellation()
            try await commitCheck()
            let commit = try await saveAgentSessionLocked(
                initialSession, for: workspace, preparation: .alreadyCanonicalTranscript,
                trustedCanonicalItemCount: nil, intentionallyRemovingFinalizedScheduledSendItems: [],
                committingTranscriptReset: nil, fileCreationPolicy: .createIfMissing,
                authority: .compatibility, countsAsFullSave: false
            )
            guard let session = commit.committedSession else {
                throw AgentScheduledSendMutationError.sessionAlreadyExists(destinationID)
            }
            #if DEBUG
                try await test_richArtifactPhase?("afterSave", destinationID)
            #endif
            try Task.checkCancellation()
            // Final placement/authority check and exposure in one non-suspending main-actor section.
            try await MainActor.run {
                try commitCheck()
                try expose(AgentSessionEditableLoad(session: session, persistenceState: commit.persistenceState))
            }
        } catch {
            await discardPrivateRecords()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                // Existing tombstone-first deletion (caches, notification, recovery, metadata and
                // the destination rich tree); this call already owns the fence.
                do {
                    try await deleteAgentSessionFileLocked(
                        fileURL, sessionID: destinationID, holdingRichFilesystemFence: true
                    )
                } catch {
                    print("[AgentSessionDataService] private handoff destination rollback failed; residue stays unexposed: \(error)")
                }
            } else if let copy {
                do {
                    try await AgentRichArtifactStore.offMain {
                        try AgentRichArtifactStore.removeSession(root: copy.root, sessionID: destinationID)
                    }
                } catch {
                    print("[AgentSessionDataService] private handoff rich cleanup failed; residue stays unexposed: \(error)")
                }
            }
            throw error
        }
    }

    // MARK: - Folder Helpers

    // Readers resolve with `agentSessionsFolderURL` or `agentSessionsFolderIfExists` and never create
    // storage; only persistence writers call `ensureAgentSessionsFolder`.

    /// Creates (if needed, with intermediates) and returns the "AgentSessions" subfolder. Writers only.
    private func ensureAgentSessionsFolder(for workspace: some AgentWorkspaceStorageReference) throws -> URL {
        let agentSessionsFolder = agentSessionsFolderURL(for: workspace)
        if !FileManager.default.fileExists(atPath: agentSessionsFolder.path) {
            try FileManager.default.createDirectory(at: agentSessionsFolder, withIntermediateDirectories: true)
        }
        return agentSessionsFolder
    }

    /// The "AgentSessions" subfolder when it exists as a directory; `nil` (and nothing created) otherwise.
    private func agentSessionsFolderIfExists(for workspace: some AgentWorkspaceStorageReference) -> URL? {
        let folder = agentSessionsFolderURL(for: workspace)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return nil
        }
        return folder
    }

    private static let agentSessionsFolderName = "AgentSessions"

    /// The "AgentSessions" subfolder location. Computes only; never touches the filesystem.
    private func agentSessionsFolderURL(for workspace: some AgentWorkspaceStorageReference) -> URL {
        workspaceFolderURL(for: workspace).appendingPathComponent(Self.agentSessionsFolderName)
    }

    /// The storage root this service persists the workspace's sessions under, and therefore the
    /// only root its rich artifact trees live beside (`agent_rich_artifacts` next to
    /// `AgentSessions`). Rich publication and handoff capture and revalidate exactly this root, so
    /// it always agrees with session persistence (including when a global custom location is set,
    /// which session persistence does not consult). Computes only.
    package nonisolated func workspaceStorageRoot(for workspace: some AgentWorkspaceStorageReference) -> URL {
        workspaceFolderURL(for: workspace)
    }

    /// The workspace's main folder (custom storage path or the default root). Computes only.
    private nonisolated func workspaceFolderURL(for workspace: some AgentWorkspaceStorageReference) -> URL {
        if let customURL = workspace.customStoragePath {
            return customURL
        }
        return workspacesRoot
            .appendingPathComponent(WorkspaceDirectoryName.directoryName(name: workspace.name, id: workspace.id))
    }
}
