import Foundation

// Strict, extras-preserving codec for `AgentRuntimeRecord`, with the session-record contract: a
// supported record re-encodes to exactly the decoded JSON value; anything else is unreadable and
// preserved.

enum AgentRuntimeRecordCodec {
    private typealias Reader = AgentRecoveryRecordCodec.Reader

    static func decode(_ data: Data, expectedRuntimeID: UUID) -> Result<AgentRuntimeRecord, AgentRecoveryUnreadableReason> {
        let json: AgentRecoveryJSONValue
        do {
            json = try JSONDecoder().decode(AgentRecoveryJSONValue.self, from: data)
        } catch {
            return .failure(.malformed("runtime record is not JSON"))
        }
        do {
            var reader = try Reader(json, path: "runtime")
            let schemaVersion = try reader.int("schemaVersion")
            guard schemaVersion == AgentRuntimeRecord.currentSchemaVersion else {
                if schemaVersion > AgentRuntimeRecord.currentSchemaVersion {
                    return .failure(.futureSchema(schemaVersion))
                }
                return .failure(.malformed("unsupported schemaVersion \(schemaVersion)"))
            }
            let runtimeID = try reader.uuid("runtimeID")
            guard runtimeID == expectedRuntimeID else {
                return .failure(.malformed("runtimeID does not match file name"))
            }
            let familyRaw = try reader.string("family")
            guard let family = AgentRuntimeFamily(rawValue: familyRaw) else {
                return .failure(.unknownVariant("runtime.family \(familyRaw)"))
            }
            let stateRaw = try reader.string("state")
            guard let state = AgentRuntimeRecord.State(rawValue: stateRaw) else {
                return .failure(.unknownVariant("runtime.state \(stateRaw)"))
            }
            // Absent in earlier draft records: unknown provider, never inferred from the family.
            let provider: AgentRuntimeProvider?
            if let providerRaw = try reader.optionalString("provider") {
                guard let known = AgentRuntimeProvider(rawValue: providerRaw) else {
                    return .failure(.unknownVariant("runtime.provider \(providerRaw)"))
                }
                provider = known
            } else {
                provider = nil
            }
            let record = try AgentRuntimeRecord(
                runtimeID: runtimeID,
                revision: AgentRecoveryRecordRevision(token: reader.string("revision")),
                appInstanceID: reader.uuid("appInstanceID"),
                family: family,
                provider: provider,
                providerHome: reader.optionalString("providerHome"),
                state: state,
                root: reader.optional("root").map { try identity($0, path: "runtime.root") },
                rootProcessGroupID: reader.optional("rootProcessGroupID").map {
                    try int32($0, path: "runtime.rootProcessGroupID")
                },
                rootReaped: reader.bool("rootReaped"),
                members: reader.array("members").enumerated().map { try member($1, path: "runtime.members[\($0)]") },
                // Absent in earlier draft records: no association is fabricated.
                associations: (reader.optional("associations").map { try array($0, path: "runtime.associations") } ?? [])
                    .enumerated().map { try association($1, path: "runtime.associations[\($0)]") },
                conversationIDs: reader.array("conversationIDs").enumerated().map {
                    try Reader.string($1, path: "runtime.conversationIDs[\($0)]")
                },
                worktreePaths: reader.array("worktreePaths").enumerated().map {
                    try Reader.string($1, path: "runtime.worktreePaths[\($0)]")
                },
                letFinish: reader.bool("letFinish"),
                createdAt: reader.timestamp("createdAt"),
                updatedAt: reader.timestamp("updatedAt"),
                extras: reader.extras
            )
            guard encodeJSON(record) == json else {
                return .failure(.malformed("runtime record does not round-trip exactly"))
            }
            return .success(record)
        } catch let error as AgentRecoveryDecodingError {
            return .failure(error.reason)
        } catch {
            return .failure(.malformed(String(describing: error)))
        }
    }

    static func encode(_ record: AgentRuntimeRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(encodeJSON(record))
    }

    static func encodeJSON(_ record: AgentRuntimeRecord) -> AgentRecoveryJSONValue {
        var object = record.extras
        object["schemaVersion"] = .number(Decimal(AgentRuntimeRecord.currentSchemaVersion))
        object["runtimeID"] = .string(record.runtimeID.uuidString)
        object["revision"] = .string(record.revision.token)
        object["appInstanceID"] = .string(record.appInstanceID.uuidString)
        object["family"] = .string(record.family.rawValue)
        if let provider = record.provider {
            object["provider"] = .string(provider.rawValue)
        }
        if let providerHome = record.providerHome {
            object["providerHome"] = .string(providerHome)
        }
        object["state"] = .string(record.state.rawValue)
        if let root = record.root {
            object["root"] = identityJSON(root)
        }
        if let group = record.rootProcessGroupID {
            object["rootProcessGroupID"] = .number(Decimal(group))
        }
        object["rootReaped"] = .bool(record.rootReaped)
        object["members"] = .array(record.members.map(memberJSON))
        if !record.associations.isEmpty {
            object["associations"] = .array(record.associations.map(associationJSON))
        }
        object["conversationIDs"] = .array(record.conversationIDs.map { .string($0) })
        object["worktreePaths"] = .array(record.worktreePaths.map { .string($0) })
        object["letFinish"] = .bool(record.letFinish)
        object["createdAt"] = .number(Decimal(record.createdAt.millisecondsSince1970))
        object["updatedAt"] = .number(Decimal(record.updatedAt.millisecondsSince1970))
        return .object(object)
    }

    // MARK: Associations

    private static func array(_ json: AgentRecoveryJSONValue, path: String) throws -> [AgentRecoveryJSONValue] {
        guard case let .array(values) = json else {
            throw AgentRecoveryDecodingError(reason: .malformed("\(path) is not an array"))
        }
        return values
    }

    private static func association(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRuntimeAssociation {
        var reader = try Reader(json, path: path)
        return try AgentRuntimeAssociation(
            session: reader.optional("session").map { try session($0, path: "\(path).session") },
            conversationID: reader.optionalString("conversationID"),
            worktreePath: reader.optionalString("worktreePath"),
            permission: permission(reader.required("permission"), path: "\(path).permission"),
            extras: reader.extras
        )
    }

    private static func associationJSON(_ association: AgentRuntimeAssociation) -> AgentRecoveryJSONValue {
        var object = association.extras
        if let session = association.session {
            object["session"] = sessionJSON(session)
        }
        if let conversationID = association.conversationID {
            object["conversationID"] = .string(conversationID)
        }
        if let worktreePath = association.worktreePath {
            object["worktreePath"] = .string(worktreePath)
        }
        object["permission"] = permissionJSON(association.permission)
        return .object(object)
    }

    /// Closed object: an unknown member would make session identity ambiguous.
    private static func session(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRuntimeSessionAssociation {
        var reader = try Reader(json, path: path)
        let session = try AgentRuntimeSessionAssociation(
            sessionID: reader.uuid("sessionID"),
            incarnationID: reader.uuid("incarnationID"),
            transcriptResetGeneration: reader.uint64("transcriptResetGeneration"),
            runAttemptID: reader.optionalUUID("runAttemptID"),
            processRunID: reader.optionalUUID("processRunID")
        )
        guard reader.extras.isEmpty else {
            throw AgentRecoveryDecodingError(reason: .malformed("\(path) has unknown members"))
        }
        return session
    }

    private static func sessionJSON(_ session: AgentRuntimeSessionAssociation) -> AgentRecoveryJSONValue {
        var object: AgentRecoveryExtras = [
            "sessionID": .string(session.sessionID.uuidString),
            "incarnationID": .string(session.incarnationID.uuidString),
            "transcriptResetGeneration": .number(Decimal(session.transcriptResetGeneration))
        ]
        if let runAttemptID = session.runAttemptID {
            object["runAttemptID"] = .string(runAttemptID.uuidString)
        }
        if let processRunID = session.processRunID {
            object["processRunID"] = .string(processRunID.uuidString)
        }
        return .object(object)
    }

    /// Closed tagged object; an unknown kind is an unknown variant (preserved, never guessed).
    private static func permission(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRuntimePermissionSnapshot {
        var reader = try Reader(json, path: path)
        let kind = try reader.string("kind")
        let snapshot: AgentRuntimePermissionSnapshot
        switch kind {
        case "unavailable":
            snapshot = .unavailable
        case "claude":
            snapshot = try .claude(permissionMode: reader.optionalString("permissionMode"))
        case "codex":
            snapshot = try .codex(approvalPolicy: reader.optionalString("approvalPolicy"), sandbox: reader.optionalString("sandbox"))
        case "acp":
            snapshot = try .acp(
                sessionModeID: reader.optionalString("sessionModeID"),
                autoApproveAllToolPermissions: reader.bool("autoApproveAllToolPermissions")
            )
        default:
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).kind \(kind)"))
        }
        guard reader.extras.isEmpty else {
            throw AgentRecoveryDecodingError(reason: .malformed("\(path) has unknown members"))
        }
        return snapshot
    }

    private static func permissionJSON(_ permission: AgentRuntimePermissionSnapshot) -> AgentRecoveryJSONValue {
        var object: AgentRecoveryExtras = [:]
        switch permission {
        case .unavailable:
            object["kind"] = .string("unavailable")
        case let .claude(permissionMode):
            object["kind"] = .string("claude")
            if let permissionMode { object["permissionMode"] = .string(permissionMode) }
        case let .codex(approvalPolicy, sandbox):
            object["kind"] = .string("codex")
            if let approvalPolicy { object["approvalPolicy"] = .string(approvalPolicy) }
            if let sandbox { object["sandbox"] = .string(sandbox) }
        case let .acp(sessionModeID, autoApprove):
            object["kind"] = .string("acp")
            if let sessionModeID { object["sessionModeID"] = .string(sessionModeID) }
            object["autoApproveAllToolPermissions"] = .bool(autoApprove)
        }
        return .object(object)
    }

    // MARK: Members and identities

    private static func member(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRuntimeMember {
        var reader = try Reader(json, path: path)
        let roleRaw = try reader.string("role")
        guard let role = AgentRuntimeMember.Role(rawValue: roleRaw) else {
            throw AgentRecoveryDecodingError(reason: .unknownVariant("\(path).role \(roleRaw)"))
        }
        return try AgentRuntimeMember(
            identity: identity(reader.required("identity"), path: "\(path).identity"),
            processGroupID: reader.optional("processGroupID").map { try int32($0, path: "\(path).processGroupID") },
            role: role,
            extras: reader.extras
        )
    }

    private static func memberJSON(_ member: AgentRuntimeMember) -> AgentRecoveryJSONValue {
        var object = member.extras
        object["identity"] = identityJSON(member.identity)
        if let group = member.processGroupID {
            object["processGroupID"] = .number(Decimal(group))
        }
        object["role"] = .string(member.role.rawValue)
        return .object(object)
    }

    /// Identities are closed objects (no extras): an extra member would make identity comparison
    /// ambiguous, so it is unreadable.
    private static func identity(_ json: AgentRecoveryJSONValue, path: String) throws -> AgentRuntimeProcessIdentity {
        var reader = try Reader(json, path: path)
        let uid = try reader.uint64("uid")
        guard let uid32 = UInt32(exactly: uid) else {
            throw AgentRecoveryDecodingError(reason: .malformed("\(path).uid is out of range"))
        }
        let identity = try AgentRuntimeProcessIdentity(
            bootSessionID: reader.uuid("bootSessionID"),
            pid: int32(reader.required("pid"), path: "\(path).pid"),
            startSeconds: reader.uint64("startSeconds"),
            startMicroseconds: reader.uint64("startMicroseconds"),
            uid: uid32
        )
        guard reader.extras.isEmpty else {
            throw AgentRecoveryDecodingError(reason: .malformed("\(path) has unknown members"))
        }
        return identity
    }

    private static func identityJSON(_ identity: AgentRuntimeProcessIdentity) -> AgentRecoveryJSONValue {
        .object([
            "bootSessionID": .string(identity.bootSessionID.uuidString),
            "pid": .number(Decimal(identity.pid)),
            "startSeconds": .number(Decimal(identity.startSeconds)),
            "startMicroseconds": .number(Decimal(identity.startMicroseconds)),
            "uid": .number(Decimal(identity.uid))
        ])
    }

    private static func int32(_ json: AgentRecoveryJSONValue, path: String) throws -> Int32 {
        guard let value = try Int32(exactly: Reader.int64(json, path: path)) else {
            throw AgentRecoveryDecodingError(reason: .malformed("\(path) is out of range"))
        }
        return value
    }
}
