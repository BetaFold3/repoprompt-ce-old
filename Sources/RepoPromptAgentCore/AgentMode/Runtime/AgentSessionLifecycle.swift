import Foundation

// Durable lifecycle authority for one persisted Agent session (lossless-restart Phase 1b).
// Only `AgentSessionDataService` creates or advances typed lifecycle values; every other
// transformation copies the member through unchanged.

/// Durable identity and transcript-reset state embedded in the version-7 session envelope.
package struct AgentSessionLifecycle: Codable, Equatable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    /// Assigned once when the session file is created or a legacy file is migrated.
    package let incarnationID: UUID
    /// Number of committed explicit transcript resets for this incarnation.
    package let transcriptResetGeneration: UInt64
    /// Receipt of the latest committed reset; present exactly when the generation is positive.
    package let lastTranscriptResetReceipt: AgentSessionTranscriptResetReceipt?

    package init(
        schemaVersion: Int = AgentSessionLifecycle.currentSchemaVersion,
        incarnationID: UUID,
        transcriptResetGeneration: UInt64 = 0,
        lastTranscriptResetReceipt: AgentSessionTranscriptResetReceipt? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.incarnationID = incarnationID
        self.transcriptResetGeneration = transcriptResetGeneration
        self.lastTranscriptResetReceipt = lastTranscriptResetReceipt
    }

    /// Fresh authority for a newly created or migrated session.
    static func fresh() -> AgentSessionLifecycle {
        AgentSessionLifecycle(incarnationID: UUID())
    }

    /// Schema and generation/receipt pairing invariants for typed authority.
    var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && (transcriptResetGeneration == 0) == (lastTranscriptResetReceipt == nil)
    }

    /// The lifecycle after committing `receipt`; `nil` on generation overflow (never wraps).
    func advancingTranscriptReset(receipt: AgentSessionTranscriptResetReceipt) -> AgentSessionLifecycle? {
        let (next, overflow) = transcriptResetGeneration.addingReportingOverflow(1)
        guard !overflow else { return nil }
        return AgentSessionLifecycle(
            schemaVersion: schemaVersion,
            incarnationID: incarnationID,
            transcriptResetGeneration: next,
            lastTranscriptResetReceipt: receipt
        )
    }
}

/// Typed-or-unreadable lifecycle member. Unlike scheduled sends, nothing is normalized: any
/// unknown schema, unknown member, explicit `null`, malformed identity, or invalid
/// generation/receipt pairing is preserved verbatim (semantically) and is never writable authority.
package enum AgentSessionLifecycleMember: Codable, Equatable {
    case v1(AgentSessionLifecycle)
    case unreadable(AgentScheduledSendJSONValue)

    package var lifecycle: AgentSessionLifecycle? {
        guard case let .v1(value) = self else { return nil }
        return value
    }

    package init(from decoder: Decoder) throws {
        let jsonValue = try AgentScheduledSendJSONValue(from: decoder)
        self = Self.member(from: jsonValue)
    }

    static func member(from jsonValue: AgentScheduledSendJSONValue) -> AgentSessionLifecycleMember {
        guard let jsonData = try? JSONEncoder().encode(jsonValue),
              let value = try? JSONDecoder().decode(AgentSessionLifecycle.self, from: jsonData),
              value.isValid,
              let typedData = try? JSONEncoder().encode(value),
              let typedJSON = try? JSONDecoder().decode(AgentScheduledSendJSONValue.self, from: typedData),
              typedJSON == jsonValue
        else {
            return .unreadable(jsonValue)
        }
        return .v1(value)
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case let .v1(value):
            try value.encode(to: encoder)
        case let .unreadable(jsonValue):
            try jsonValue.encode(to: encoder)
        }
    }
}

/// Permanent, session-UUID-wide deletion record written before a session file is unlinked.
/// A tombstone retires its UUID in every workspace; same-ID recreation is refused.
package struct AgentSessionDeletionTombstone: Codable, Equatable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let sessionID: UUID

    package init(schemaVersion: Int = AgentSessionDeletionTombstone.currentSchemaVersion, sessionID: UUID) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
    }
}

/// Durable deletion state for one session UUID. Anything other than `.absent` fences writes.
package enum AgentSessionTombstoneState: Equatable {
    case absent
    case committed
    /// A tombstone file exists but cannot be verified; it is never replaced automatically.
    case unreadable
}
