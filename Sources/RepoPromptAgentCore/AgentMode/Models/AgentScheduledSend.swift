import Foundation

// MARK: - Scheduled Send Persistence

package struct AgentScheduledSendPersist: Codable, Equatable {
    package enum State: String, Codable, Equatable {
        case scheduled
        case needsConfirmation
        case dispatching
        case failed

        package init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            self = State(rawValue: rawValue) ?? .needsConfirmation
        }
    }

    package enum ConfirmationReason: String, Codable, Equatable {
        case missedWhileClosed
        case missedDuringSleep
        case clockChanged
        case runNotCompleted
        case deliveryUnknown
        case destinationUnavailable

        package var displayText: String {
            switch self {
            case .missedWhileClosed: "app was closed; confirmation required"
            case .missedDuringSleep: "Mac was asleep; confirmation required"
            case .clockChanged: "system clock changed; confirmation required"
            case .runNotCompleted: "the blocking run did not complete; confirmation required"
            case .deliveryUnknown: "delivery unconfirmed"
            case .destinationUnavailable: "destination unavailable"
            }
        }
    }

    package struct Attempt: Codable, Equatable {
        package let attemptID: UUID
        package let itemID: UUID
        let startedAt: Date

        package init(
            attemptID: UUID,
            itemID: UUID,
            startedAt: Date
        ) {
            self.attemptID = attemptID
            self.itemID = itemID
            self.startedAt = startedAt
        }
    }

    package let id: UUID
    var createdAt: Date
    package var updatedAt: Date
    package var notBefore: Date
    package var state: State
    package var confirmationReason: ConfirmationReason?
    package var rawText: String
    package var attachments: [AgentImageAttachment]
    package var taggedFileAttachments: [AgentTaggedFileAttachment]
    package var workflow: AgentWorkflowDefinition?
    package var interviewFirst: Bool
    package var isNewSessionStart: Bool
    package var runAlongsideOtherSessions: Bool
    package var firstEligibleAt: Date?
    package var attempt: Attempt?
    package var lastFailureMessage: String?

    package init(
        id: UUID,
        createdAt: Date,
        updatedAt: Date,
        notBefore: Date,
        state: State,
        confirmationReason: ConfirmationReason? = nil,
        rawText: String,
        attachments: [AgentImageAttachment],
        taggedFileAttachments: [AgentTaggedFileAttachment],
        workflow: AgentWorkflowDefinition? = nil,
        interviewFirst: Bool,
        isNewSessionStart: Bool,
        runAlongsideOtherSessions: Bool,
        firstEligibleAt: Date? = nil,
        attempt: Attempt? = nil,
        lastFailureMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notBefore = notBefore
        self.state = state
        self.confirmationReason = confirmationReason
        self.rawText = rawText
        self.attachments = attachments
        self.taggedFileAttachments = taggedFileAttachments
        self.workflow = workflow
        self.interviewFirst = interviewFirst
        self.isNewSessionStart = isNewSessionStart
        self.runAlongsideOtherSessions = runAlongsideOtherSessions
        self.firstEligibleAt = firstEligibleAt
        self.attempt = attempt
        self.lastFailureMessage = lastFailureMessage
    }
}

/// R9 link from a `savedInQueue` schedule receipt to the durable recovery intent that now owns the
/// scheduled input. `userItemID` is the schedule attempt's deterministic transcript item.
public struct AgentScheduledSendQueueLink: Equatable, Sendable {
    public let intentID: UUID
    public let userItemID: UUID

    public init(intentID: UUID, userItemID: UUID) {
        self.intentID = intentID
        self.userItemID = userItemID
    }
}

/// What a historical schedule receipt proves (R9). Exactly three kinds:
/// - `providerAccepted`: affirmative provider (or durable recovery) acceptance evidence existed.
/// - `savedInQueue`: the input was transferred to a durable recovery intent that was `queued`
///   when the receipt was written. Saved input, never delivery evidence.
/// - `legacyUnknown`: written before receipt kinds existed, or a kind this build cannot read (its
///   raw fields are retained for re-encoding); proves neither.
public enum AgentScheduledSendReceiptKind: Equatable, Sendable {
    case providerAccepted
    case savedInQueue(AgentScheduledSendQueueLink)
    case legacyUnknown
}

public struct AgentScheduledSendProvenance: Codable, Equatable, Sendable {
    public let scheduleID: UUID
    /// Schedule dispatch attempt (`AgentScheduledSendPersist.Attempt.attemptID`).
    public let attemptID: UUID
    public let scheduledFor: Date
    public let sentAt: Date
    public let kind: AgentScheduledSendReceiptKind
    /// Receipt fields this build does not interpret (an unknown or incomplete future kind, or extra
    /// keys), kept verbatim so a re-save is lossless. Never consulted for `kind`.
    private let retainedFields: [String: AgentScheduledSendJSONValue]

    /// Receipt without delivery evidence (`legacyUnknown`). Producers that hold acceptance or a
    /// durable transfer must pass `kind` explicitly; this initializer never claims acceptance.
    public init(scheduleID: UUID, attemptID: UUID, scheduledFor: Date, sentAt: Date) {
        self.init(scheduleID: scheduleID, attemptID: attemptID, scheduledFor: scheduledFor, sentAt: sentAt, kind: .legacyUnknown)
    }

    public init(scheduleID: UUID, attemptID: UUID, scheduledFor: Date, sentAt: Date, kind: AgentScheduledSendReceiptKind) {
        self.scheduleID = scheduleID
        self.attemptID = attemptID
        self.scheduledFor = scheduledFor
        self.sentAt = sentAt
        self.kind = kind
        retainedFields = [:]
    }

    public var isProviderAccepted: Bool {
        kind == .providerAccepted
    }

    public var queueLink: AgentScheduledSendQueueLink? {
        if case let .savedInQueue(link) = kind {
            return link
        }
        return nil
    }

    /// One keyed container for typed and retained fields alike.
    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? {
            nil
        }

        init(_ stringValue: String) {
            self.stringValue = stringValue
        }

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue _: Int) {
            nil
        }

        static let scheduleID = FieldKey("scheduleID")
        static let attemptID = FieldKey("attemptID")
        static let scheduledFor = FieldKey("scheduledFor")
        static let sentAt = FieldKey("sentAt")
        static let receiptKind = FieldKey("receiptKind")
        static let intentID = FieldKey("intentID")
        static let userItemID = FieldKey("userItemID")
    }

    private enum KindRawValue: String {
        case providerAccepted
        case savedInQueue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FieldKey.self)
        scheduleID = try container.decode(UUID.self, forKey: .scheduleID)
        attemptID = try container.decode(UUID.self, forKey: .attemptID)
        scheduledFor = try container.decode(Date.self, forKey: .scheduledFor)
        sentAt = try container.decode(Date.self, forKey: .sentAt)
        var interpreted: Set<String> = [
            FieldKey.scheduleID.stringValue,
            FieldKey.attemptID.stringValue,
            FieldKey.scheduledFor.stringValue,
            FieldKey.sentAt.stringValue
        ]
        // Old data has no kind; an unknown or incomplete kind never becomes acceptance or a link.
        // Its raw fields stay uninterpreted and are retained below.
        let rawKind: String? = try? container.decodeIfPresent(String.self, forKey: .receiptKind)
        switch rawKind.flatMap(KindRawValue.init(rawValue:)) {
        case .providerAccepted?:
            kind = .providerAccepted
            interpreted.insert(FieldKey.receiptKind.stringValue)
        case .savedInQueue?:
            let intentID: UUID? = try? container.decodeIfPresent(UUID.self, forKey: .intentID)
            let userItemID: UUID? = try? container.decodeIfPresent(UUID.self, forKey: .userItemID)
            if let intentID, let userItemID {
                kind = .savedInQueue(AgentScheduledSendQueueLink(intentID: intentID, userItemID: userItemID))
                interpreted.formUnion([
                    FieldKey.receiptKind.stringValue,
                    FieldKey.intentID.stringValue,
                    FieldKey.userItemID.stringValue
                ])
            } else {
                kind = .legacyUnknown
            }
        case nil:
            kind = .legacyUnknown
        }
        var retained: [String: AgentScheduledSendJSONValue] = [:]
        for key in container.allKeys where !interpreted.contains(key.stringValue) {
            if let value = try? container.decode(AgentScheduledSendJSONValue.self, forKey: key) {
                retained[key.stringValue] = value
            }
        }
        retainedFields = retained
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: FieldKey.self)
        try container.encode(scheduleID, forKey: .scheduleID)
        try container.encode(attemptID, forKey: .attemptID)
        try container.encode(scheduledFor, forKey: .scheduledFor)
        try container.encode(sentAt, forKey: .sentAt)
        var written: Set<String> = [
            FieldKey.scheduleID.stringValue,
            FieldKey.attemptID.stringValue,
            FieldKey.scheduledFor.stringValue,
            FieldKey.sentAt.stringValue
        ]
        switch kind {
        case .providerAccepted:
            try container.encode(KindRawValue.providerAccepted.rawValue, forKey: .receiptKind)
            written.insert(FieldKey.receiptKind.stringValue)
        case let .savedInQueue(link):
            try container.encode(KindRawValue.savedInQueue.rawValue, forKey: .receiptKind)
            try container.encode(link.intentID, forKey: .intentID)
            try container.encode(link.userItemID, forKey: .userItemID)
            written.formUnion([
                FieldKey.receiptKind.stringValue,
                FieldKey.intentID.stringValue,
                FieldKey.userItemID.stringValue
            ])
        case .legacyUnknown:
            // Absent kind is the legacy encoding; old builds decode the receipt unchanged. A
            // retained unreadable kind is written back verbatim below.
            break
        }
        for (key, value) in retainedFields.sorted(by: { $0.key < $1.key }) where !written.contains(key) {
            try container.encode(value, forKey: FieldKey(key))
        }
    }
}

/// Semantic JSON representation used to retain a scheduled-send member that this build cannot read.
///
/// Object member order and numeric spelling are not preserved, but the decoded JSON value is.
package enum AgentScheduledSendJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([AgentScheduledSendJSONValue])
    case object([String: AgentScheduledSendJSONValue])

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgentScheduledSendJSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: AgentScheduledSendJSONValue].self))
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    fileprivate var normalizingUnknownScheduledSendState: AgentScheduledSendJSONValue {
        guard case var .object(object) = self,
              case let .string(rawState)? = object["state"],
              AgentScheduledSendPersist.State(rawValue: rawState) == nil
        else {
            return self
        }
        object["state"] = .string(AgentScheduledSendPersist.State.needsConfirmation.rawValue)
        return .object(object)
    }
}

package enum AgentScheduledSendMember: Codable, Equatable {
    case v1(AgentScheduledSendPersist)
    case unreadable(AgentScheduledSendJSONValue)

    package var persistedValue: AgentScheduledSendPersist? {
        guard case let .v1(value) = self else { return nil }
        return value
    }

    package var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }

    package init(from decoder: Decoder) throws {
        let jsonValue = try AgentScheduledSendJSONValue(from: decoder)
        let jsonData = try JSONEncoder().encode(jsonValue)

        guard let value = try? JSONDecoder().decode(AgentScheduledSendPersist.self, from: jsonData),
              let typedData = try? JSONEncoder().encode(value),
              let typedJSON = try? JSONDecoder().decode(AgentScheduledSendJSONValue.self, from: typedData),
              typedJSON == jsonValue.normalizingUnknownScheduledSendState
        else {
            self = .unreadable(jsonValue)
            return
        }

        self = .v1(value)
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
