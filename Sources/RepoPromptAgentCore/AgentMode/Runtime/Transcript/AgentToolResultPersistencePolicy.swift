import Foundation
import RepoPromptWorkspace

struct AgentSanitizedToolResult: Equatable {
    let text: String
    let resultJSON: String?
    let toolIsError: Bool?
    let persistedStatusWord: String
    let transcriptStatus: AgentTranscriptToolStatus
    let summaryOnly: Bool
    let processID: String?
    let exitCode: Int?
    let preservesRawPayload: Bool

    var shouldRetainEphemeralRawPayload: Bool {
        !preservesRawPayload && summaryOnly
    }
}

/// Outcome of the trusted activity-suffix sanitize path. Payload-free; diagnostics only.
enum AgentSanitizeIncrementalPathReason: String, Equatable {
    /// The activity-suffix path produced the result.
    case activitySuffixSuccess
    /// Persistent-storage sanitization never attempts the activity-suffix path.
    case notRuntimePresentation
    /// No trusted incremental final-turn start sequence index was supplied.
    case trustedSuffixUnavailable
    /// No previous sanitized transcript was supplied.
    case previousSanitizedTranscriptUnavailable
    case turnCountMismatch
    /// The validated reusable prefix does not cover every turn before the final turn.
    case reusedPrefixMismatch
    case finalTurnMissing
    case finalTurnIdentityMismatch
    case requestMismatch
    case spanCountMismatch
    case spanIdentityMismatch
    /// An unchanged span's activity count or first/last identity differs from the previous span.
    case unchangedSpanMismatch
    /// The changed-activity index lies beyond the previous span's activities.
    case changedActivityIndexOutOfRange
    /// The activity immediately before the changed suffix differs from the previous span.
    case prefixBoundaryMismatch
    case changedSuffixNotFound
    /// The raw-input activity comparison path produced the result: every activity was either
    /// processed normally or reused from the previous output after full raw-input equality.
    case rawInputActivityComparison
}

package struct AgentSanitizedTranscriptMetrics: Equatable {
    /// Mutable only so rich-presentation capture can attach turn-owned references after any path.
    package var transcript: AgentTranscript
    let sanitizedActivityCount: Int
    let reusedTurnCount: Int
    let incrementalPathReason: AgentSanitizeIncrementalPathReason
    /// Activities installed from the previous output instead of being processed (raw-input
    /// comparison path only), whatever their replayed flag. Work-count evidence; never drives
    /// retention.
    var reusedActivityCount: Int = 0
    /// For each turn → span → activity of the input, the Boolean that runtime processing
    /// returned (or replayed) for it. Nil when any activity was installed without being processed
    /// or replayed from evidence (prefix or suffix reuse), processing was skipped for tool-kind
    /// activities, rows were explicitly preserved, or the purpose was persistent storage.
    var activityProcessingFlags: [[[Bool]]]?
}

/// Session-local D4 evidence for one applied runtime build: its exact pre-sanitize input and,
/// aligned with that input's turn → span → activity traversal, the Boolean that runtime
/// processing (tool-identity normalization || runtime sanitization, no preserved rows) returned.
/// Paired with the build's sanitized output, which the session holds as its transcript.
package struct AgentSanitizeRawInputEvidence: Equatable {
    let importedTranscript: AgentTranscript
    let activityProcessingFlags: [[[Bool]]]
}

struct AgentPersistedToolResultSummary: Equatable {
    let resultJSON: String
    let statusWord: String
    let transcriptStatus: AgentTranscriptToolStatus
    let toolIsError: Bool?
    let processID: String?
    let exitCode: Int?
    let summaryText: String
    let summaryOnly: Bool
}

struct AgentToolResultRetentionInspection: Equatable {
    let isToolResult: Bool
    let summaryOnly: Bool?
    let preservesRawPayload: Bool?
    let retainsEphemeralRawPayload: Bool
    let retainedPayload: String?
    let rawPayloadByteCount: Int
    let persistedPayloadByteCount: Int?
}

package enum AgentToolResultSanitizationPurpose {
    case runtimePresentation
    case persistentStorage
}

package enum AgentToolResultPersistencePolicy {
    static let maxPersistedToolSummaryBytes = 2048
    private static let cursorACPPersistedDiffBytesLimit = 1200
    private static let cursorACPFallbackPersistedDiffBytesLimit = 600
    private static let cursorACPGeneratedDiffInputBytesLimit = 16384
    private static let cursorACPGeneratedDiffInputLineLimit = 800
    private static let promptExportFileMetadataLimit = 12

    static func sanitizeItem(_ item: AgentChatItem) -> AgentChatItem {
        guard let sanitized = sanitizedToolResult(for: item) else { return item }
        var updated = item
        updated.text = sanitized.text
        updated.toolResultJSON = sanitized.resultJSON
        updated.toolIsError = sanitized.toolIsError
        return updated
    }

    /// Pure in `item` and `toolExecution`. `context` only memoizes content-keyed work (JSON
    /// objects, bash metadata) and records metrics, except that a nil `toolExecution` is resolved
    /// through `AgentTranscriptToolNormalizer.toolExecution(for:context:)`, which reads and
    /// writes the context's per-ID execution state for `item.id` alone. No other item, payload
    /// map, revision, setting, or session state is read. Runtime raw-input reuse
    /// (`RawInputReuseCandidates`) relies on this: with an embedded execution, equal inputs
    /// produce equal results.
    static func sanitizedToolResult(
        for item: AgentChatItem,
        toolExecution: AgentTranscriptToolExecution? = nil,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentSanitizedToolResult? {
        guard item.kind == .toolResult else { return nil }
        // Keep delivered runtime notices verbatim while summarizing the original tool
        // payload normally. Their ID-bearing question content is what the model saw.
        if let raw = item.toolResultJSON,
           raw.contains(AgentDelegatedQuestionNoticeWire.resultKey),
           var object = jsonObject(from: raw, context: context),
           let notices = object.removeValue(forKey: AgentDelegatedQuestionNoticeWire.resultKey),
           let originalJSON = jsonString(from: object)
        {
            var originalItem = item
            originalItem.toolResultJSON = originalJSON
            // Only the mirrored raw payload carries the notices; a distinct rendered
            // `text` is the tool's own presentation and must reach the summarizer intact.
            if item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == raw.trimmingCharacters(in: .whitespacesAndNewlines)
            {
                originalItem.text = originalJSON
            }
            guard let original = sanitizedToolResult(for: originalItem, toolExecution: toolExecution, context: context) else { return nil }
            let resultJSON = preservingDelegatedQuestionNotices(notices, in: original.resultJSON ?? original.text)
            return AgentSanitizedToolResult(
                text: resultJSON,
                resultJSON: resultJSON,
                toolIsError: original.toolIsError,
                persistedStatusWord: original.persistedStatusWord,
                transcriptStatus: original.transcriptStatus,
                summaryOnly: original.summaryOnly,
                processID: original.processID,
                exitCode: original.exitCode,
                preservesRawPayload: original.preservesRawPayload
            )
        }
        let normalizedToolName = normalizedToolName(item.toolName)
        let rawResultJSON = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preservedText = rawResultJSON?.isEmpty == false ? rawResultJSON! : item.text
        if normalizedToolName == "ask_user" || normalizedToolName == "ask_user_question" {
            let execution = toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
            let status = execution?.status ?? AgentTranscriptToolNormalizer.status(for: item, context: context)
            let statusWord = AgentTranscriptToolStatusSemantics.persistedStatusWord(from: status)
            return AgentSanitizedToolResult(
                text: preservedText,
                resultJSON: item.toolResultJSON,
                toolIsError: item.toolIsError,
                persistedStatusWord: statusWord,
                transcriptStatus: status,
                summaryOnly: false,
                processID: execution?.processID,
                exitCode: execution?.exitCode,
                preservesRawPayload: true
            )
        }

        // A recognized successful `present_rich` result is stored as its canonical text body. The
        // turn-owned reference (captured before sanitization) is the durable authority, so a later
        // persistent cap replacing this body loses nothing. Errors and anything unrecognized fall
        // through to ordinary handling.
        if normalizedToolName == AgentRichPresentationToolPolicy.toolName,
           AgentRichPresentationResultNormalizer.isPresentRichToolName(item.toolName),
           item.toolIsError != true,
           let rawResultJSON,
           let reference = AgentRichPresentationResultNormalizer.reference(fromResultText: rawResultJSON),
           let canonical = AgentRichPresentationResultNormalizer.canonicalResultJSON(for: reference)
        {
            return AgentSanitizedToolResult(
                text: canonical,
                resultJSON: canonical,
                toolIsError: false,
                persistedStatusWord: "success",
                transcriptStatus: .success,
                summaryOnly: false,
                processID: nil,
                exitCode: nil,
                preservesRawPayload: false
            )
        }

        if normalizedToolName == "agent_run" || normalizedToolName == "agent_explore" {
            let rawObject = jsonObject(from: rawResultJSON, context: context)
            let statusWord = normalizedAgentRunStatusWord(stringValue(rawObject, keys: ["status"])) ?? "unknown"
            let transcriptStatus = transcriptStatusForAgentRunStatusWord(statusWord)
            let summaryJSON = agentRunSummaryJSON(normalizedToolName: normalizedToolName, statusWord: statusWord, rawObject: rawObject)
            let text = summaryJSON ?? minimalResultJSON(statusWord: statusWord)
            return AgentSanitizedToolResult(
                text: text,
                resultJSON: summaryJSON ?? minimalResultJSON(statusWord: statusWord),
                toolIsError: item.toolIsError,
                persistedStatusWord: statusWord,
                transcriptStatus: transcriptStatus,
                summaryOnly: true,
                processID: nil,
                exitCode: nil,
                preservesRawPayload: false
            )
        }

        let execution = toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
        if normalizedToolName == "prompt",
           let rawObject = jsonObject(from: rawResultJSON, context: context),
           let promptExportJSON = promptExportMetadataJSON(rawObject: rawObject)
        {
            let statusWord: String = {
                if let executionStatus = execution?.status,
                   executionStatus != .unknown
                {
                    return AgentTranscriptToolStatusSemantics.persistedStatusWord(from: executionStatus)
                }
                return derivedStatusWord(
                    normalizedToolName: normalizedToolName,
                    rawResultJSON: rawResultJSON,
                    rawObject: rawObject,
                    executionStatus: execution?.status,
                    toolIsError: item.toolIsError,
                    context: context
                )
            }()
            let status = AgentTranscriptToolStatusSemantics.transcriptStatus(fromNormalizedStatusWord: statusWord)
            return AgentSanitizedToolResult(
                text: promptExportJSON,
                resultJSON: promptExportJSON,
                toolIsError: persistedToolIsError(
                    normalizedToolName: normalizedToolName,
                    status: status,
                    original: item.toolIsError
                ),
                persistedStatusWord: statusWord,
                transcriptStatus: status,
                summaryOnly: false,
                processID: execution?.processID,
                exitCode: execution?.exitCode,
                preservesRawPayload: true
            )
        }

        let requiresStructuredSummaryDetails = normalizedToolName == "apply_edits"
            || normalizedToolName == "apply_patch"
            || normalizedToolName == "agent_run"
            || normalizedToolName == "agent_explore"
            || normalizedToolName == "agent_manage"
            || normalizedToolName == "ask_oracle"
            || normalizedToolName == "oracle_send"
            || normalizedToolName == "context_builder"
        let looksLikeCursorACPPayload = rawResultJSON?.contains("\"acp_status\"") == true
        let needsRawObjectFallbacks =
            requiresStructuredSummaryDetails
                || looksLikeCursorACPPayload
                || (normalizedToolName != "bash" && execution == nil)
                || (normalizedToolName != "bash" && execution?.status == .unknown)
                || (normalizedToolName != "bash" && execution?.processID == nil)
                || (normalizedToolName != "bash" && execution?.exitCode == nil)
        let rawObject = needsRawObjectFallbacks ? jsonObject(from: rawResultJSON, context: context) : nil
        let shouldParseBashMetadata = normalizedToolName == "bash"
        let bashMetadata = shouldParseBashMetadata
            ? BashToolResultParser.parseMetadata(raw: rawResultJSON, context: context)
            : nil
        let statusWord: String = {
            if normalizedToolName != "bash",
               let executionStatus = execution?.status,
               executionStatus != .unknown
            {
                return AgentTranscriptToolStatusSemantics.persistedStatusWord(from: executionStatus)
            }
            return derivedStatusWord(
                normalizedToolName: normalizedToolName,
                rawResultJSON: rawResultJSON,
                rawObject: rawObject,
                executionStatus: execution?.status,
                toolIsError: item.toolIsError,
                context: context
            )
        }()
        let status = AgentTranscriptToolStatusSemantics.transcriptStatus(fromNormalizedStatusWord: statusWord)
        let rawOutputObject = rawObject?["rawOutput"] as? [String: Any]
        let processID = execution?.processID
            ?? bashMetadata?.processID
            ?? stringValue(rawObject, keys: ["processId", "process_id"])
            ?? stringValue(rawOutputObject, keys: ["processId", "process_id"])
            ?? bashTextProcessID(from: rawResultJSON, context: context)
        let exitCode = execution?.exitCode
            ?? bashMetadata?.exitCode
            ?? intValue(rawObject, keys: ["exitCode", "exit_code", "code"])
            ?? intValue(rawOutputObject, keys: ["exitCode", "exit_code", "code"])
            ?? bashTextExitCode(from: rawResultJSON, context: context)
        let summaryJSON = sanitizedSummaryJSON(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            rawObject: rawObject,
            argsJSON: item.toolArgsJSON,
            rawResultText: rawResultJSON?.isEmpty == false ? rawResultJSON : item.text,
            toolIsError: item.toolIsError,
            context: context
        )
        let persistedToolIsError = persistedToolIsError(
            normalizedToolName: normalizedToolName,
            status: status,
            original: item.toolIsError
        )
        let text = summaryJSON ?? minimalResultJSON(statusWord: statusWord)
        return AgentSanitizedToolResult(
            text: text,
            resultJSON: summaryJSON ?? minimalResultJSON(statusWord: statusWord),
            toolIsError: persistedToolIsError,
            persistedStatusWord: statusWord,
            transcriptStatus: status,
            summaryOnly: true,
            processID: processID,
            exitCode: exitCode,
            preservesRawPayload: false
        )
    }

    static func inspectRetention(
        for item: AgentChatItem,
        toolExecution: AgentTranscriptToolExecution? = nil,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentToolResultRetentionInspection {
        let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard item.kind == .toolResult else {
            return AgentToolResultRetentionInspection(
                isToolResult: false,
                summaryOnly: nil,
                preservesRawPayload: nil,
                retainsEphemeralRawPayload: false,
                retainedPayload: nil,
                rawPayloadByteCount: raw.utf8.count,
                persistedPayloadByteCount: nil
            )
        }
        guard let sanitized = sanitizedToolResult(for: item, toolExecution: toolExecution, context: context) else {
            return AgentToolResultRetentionInspection(
                isToolResult: true,
                summaryOnly: nil,
                preservesRawPayload: nil,
                retainsEphemeralRawPayload: false,
                retainedPayload: nil,
                rawPayloadByteCount: raw.utf8.count,
                persistedPayloadByteCount: nil
            )
        }
        let persisted = sanitized.resultJSON?.trimmingCharacters(in: .whitespacesAndNewlines)
        let retainedPayload: String? = {
            guard sanitized.shouldRetainEphemeralRawPayload,
                  !raw.isEmpty,
                  raw != (persisted ?? "")
            else {
                return nil
            }
            return raw
        }()
        return AgentToolResultRetentionInspection(
            isToolResult: true,
            summaryOnly: sanitized.summaryOnly,
            preservesRawPayload: sanitized.preservesRawPayload,
            retainsEphemeralRawPayload: retainedPayload != nil,
            retainedPayload: retainedPayload,
            rawPayloadByteCount: raw.utf8.count,
            persistedPayloadByteCount: persisted?.utf8.count
        )
    }

    static func retainedEphemeralRawPayload(
        for item: AgentChatItem,
        toolExecution: AgentTranscriptToolExecution? = nil,
        context: AgentToolResultProcessingContext? = nil
    ) -> String? {
        inspectRetention(for: item, toolExecution: toolExecution, context: context).retainedPayload
    }

    static func shouldRetainEphemeralRawPayload(for item: AgentChatItem) -> Bool {
        retainedEphemeralRawPayload(for: item) != nil
    }

    static func persistedToolResultSummary(
        for item: AgentChatItem,
        toolExecution: AgentTranscriptToolExecution? = nil,
        rawResultTextFallback: String? = nil,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentPersistedToolResultSummary? {
        guard item.kind == .toolResult else { return nil }
        let generatedExecution = toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
        let normalizedToolName = normalizedToolName(generatedExecution?.toolName ?? item.toolName)
        let rawCandidates = storageRawPayloadCandidates(
            executionResultJSON: generatedExecution?.resultJSON,
            itemResultJSON: item.toolResultJSON,
            textFallback: rawResultTextFallback ?? item.text
        )
        var sourceItem = item
        if let rawPayload = firstStorageRawPayload(from: rawCandidates) {
            sourceItem.toolResultJSON = rawPayload
            sourceItem.text = rawPayload
        }
        let sanitized = sanitizedToolResult(
            for: sourceItem,
            toolExecution: generatedExecution,
            context: context
        )
        let transcriptStatus = sanitized?.transcriptStatus
            ?? generatedExecution?.status
            ?? AgentTranscriptToolNormalizer.status(for: sourceItem, context: context)
        let statusWord = sanitized?.persistedStatusWord
            ?? AgentTranscriptToolStatusSemantics.persistedStatusWord(from: transcriptStatus)
        let processID = storageSafeMetadataString(sanitized?.processID ?? generatedExecution?.processID)
        let exitCode = sanitized?.exitCode ?? generatedExecution?.exitCode
        let renderSummary = storageSafeRenderSummary(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            rawResultJSONCandidates: rawCandidates,
            argsJSON: sourceItem.toolArgsJSON ?? generatedExecution?.argsJSON,
            context: context,
            allowExistingSummaryOnly: generatedExecution?.summaryOnly == true
        )
        let summaryText = renderSummary?.inlineSummaryText ?? storageSafeSummaryText(
            normalizedToolName: normalizedToolName,
            toolName: generatedExecution?.toolName ?? item.toolName,
            status: transcriptStatus,
            rawResultJSONCandidates: rawCandidates,
            argsJSON: sourceItem.toolArgsJSON,
            context: context
        )
        let fallbackWithMetadata = minimalResultJSON(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: processID,
            exitCode: exitCode,
            summaryText: summaryText,
            renderSummary: renderSummary
        )
        let cursorACPStructuredSummary = storageSafeCursorACPStructuredSummary(
            sanitized?.resultJSON,
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            context: context
        )
        let allowedStructuredSummary: String? = {
            let allowedTools: Set = [
                "apply_edits",
                "ask_oracle",
                "oracle_send",
                "context_builder"
            ]
            guard let normalizedToolName,
                  let resultJSON = sanitized?.resultJSON,
                  !exceedsPersistedToolSummaryBudget(resultJSON)
            else {
                return nil
            }
            if allowedTools.contains(normalizedToolName) {
                return resultJSON
            }
            if normalizedToolName == "agent_manage",
               let object = jsonObject(from: resultJSON, context: context),
               let countSummary = agentManageCountSummaryJSON(statusWord: statusWord, rawObject: object),
               !exceedsPersistedToolSummaryBudget(countSummary)
            {
                return countSummary
            }
            return nil
        }()
        let promptExportStructuredMetadata: String? = {
            guard normalizedToolName == "prompt",
                  let resultJSON = sanitized?.resultJSON,
                  sanitized?.summaryOnly == false,
                  !exceedsPersistedToolSummaryBudget(resultJSON)
            else {
                return nil
            }
            return resultJSON
        }()
        let boundedFallback = exceedsPersistedToolSummaryBudget(fallbackWithMetadata)
            ? minimalResultJSON(statusWord: statusWord, normalizedToolName: normalizedToolName)
            : fallbackWithMetadata
        let lifecycleWaitPolicySummary = lifecycleWaitPolicyFallbackJSON(
            normalizedToolName: normalizedToolName,
            sanitizedResultJSON: sanitized?.resultJSON,
            fallbackJSON: boundedFallback,
            statusWord: statusWord,
            context: context
        )
        let completeExchangeJSON = completeAskUserExchangeResultJSON(
            normalizedToolName: normalizedToolName,
            sanitized: sanitized,
            context: context
        )
        let resultJSON = completeExchangeJSON
            ?? promptExportStructuredMetadata
            ?? cursorACPStructuredSummary
            ?? allowedStructuredSummary
            ?? lifecycleWaitPolicySummary
            ?? boundedFallback
        let notices = rawCandidates.compactMap {
            jsonObject(from: $0, context: context)?[AgentDelegatedQuestionNoticeWire.resultKey]
        }.first
        return AgentPersistedToolResultSummary(
            resultJSON: notices.map { preservingDelegatedQuestionNotices($0, in: resultJSON) } ?? resultJSON,
            statusWord: statusWord,
            transcriptStatus: transcriptStatus,
            toolIsError: sanitized?.toolIsError ?? generatedExecution?.toolIsError ?? item.toolIsError,
            processID: processID,
            exitCode: exitCode,
            summaryText: summaryText,
            summaryOnly: promptExportStructuredMetadata == nil && completeExchangeJSON == nil
        )
    }

    /// A completed `ask_user` exchange persists verbatim so a reloaded card still shows the full
    /// question and answer: its args are the agent's questions and its result holds only the
    /// submitted answers (never drafts). Like delivered question notices, it bypasses the summary
    /// byte budget. An already summarized legacy payload stays a summary.
    private static let completeExchangeToolNames: Set<String> = ["ask_user", "ask_user_question"]

    private static func completeAskUserExchangeResultJSON(
        normalizedToolName: String?,
        sanitized: AgentSanitizedToolResult?,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        guard let normalizedToolName,
              completeExchangeToolNames.contains(normalizedToolName),
              let sanitized,
              sanitized.preservesRawPayload,
              let resultJSON = sanitized.resultJSON,
              !resultJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              boolValue(jsonObject(from: resultJSON, context: context), keys: ["summary_only", "summaryOnly"]) != true
        else {
            return nil
        }
        return resultJSON
    }

    /// The ordinary summary remains byte-bounded; delivered question notices are an
    /// additive exception because truncating them would lose the parent's actual input.
    /// A non-object summary (array, scalar, or plain text) is wrapped under `summary`
    /// so the notices are never dropped merely because the summary is not an object.
    /// Internal (not private) so the non-object shape can be pinned directly by tests.
    static func preservingDelegatedQuestionNotices(_ notices: Any, in summaryJSON: String) -> String {
        if var object = jsonObject(from: summaryJSON) {
            object[AgentDelegatedQuestionNoticeWire.resultKey] = notices
            return jsonString(from: object) ?? summaryJSON
        }
        let trimmed = summaryJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: Any = trimmed.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            ?? summaryJSON
        return jsonString(from: [
            "summary": summary,
            AgentDelegatedQuestionNoticeWire.resultKey: notices
        ]) ?? summaryJSON
    }

    private static func lifecycleWaitPolicyFallbackJSON(
        normalizedToolName: String?,
        sanitizedResultJSON: String?,
        fallbackJSON: String,
        statusWord: String,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        guard normalizedToolName == "agent_run" || normalizedToolName == "agent_explore",
              let sanitizedObject = jsonObject(from: sanitizedResultJSON, context: context),
              let waitPolicy = AgentMCPWaitPolicy.canonicalMetadata(from: sanitizedObject)
        else {
            return nil
        }

        func mergingPolicy(into baseJSON: String) -> String? {
            guard var object = jsonObject(from: baseJSON, context: context) else { return nil }
            object[AgentMCPWaitPolicy.waitPolicyKey] = waitPolicy.jsonObject
            guard let json = jsonString(from: object),
                  !exceedsPersistedToolSummaryBudget(json)
            else {
                return nil
            }
            return json
        }

        if let merged = mergingPolicy(into: fallbackJSON) {
            return merged
        }
        return mergingPolicy(
            into: minimalResultJSON(
                statusWord: statusWord,
                normalizedToolName: normalizedToolName
            )
        )
    }

    private static func storageRawPayloadCandidates(
        executionResultJSON: String?,
        itemResultJSON: String?,
        textFallback: String?
    ) -> [String?] {
        [executionResultJSON, itemResultJSON, textFallback]
    }

    private static func firstStorageRawPayload(from candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    private static func promptExportMetadataJSON(rawObject: [String: Any]) -> String? {
        guard trimmedStorageString(stringValue(rawObject, keys: ["op"]))?.lowercased() == "export",
              let rawExport = rawObject["export"] as? [String: Any],
              let path = storageSafeMetadataString(stringValue(rawExport, keys: ["path"])),
              let tokens = intValue(rawExport, keys: ["tokens"]),
              let bytes = intValue(rawExport, keys: ["bytes"])
        else { return nil }

        let coreExportObject: [String: Any] = [
            "path": path,
            "tokens": tokens,
            "bytes": bytes
        ]
        let cappedFiles = promptExportFileMetadata(rawExport["files"] as? [[String: Any]], limit: promptExportFileMetadataLimit)
        let copyPreset = promptExportCopyPresetMetadata(rawExport["copy_preset"] as? [String: Any])
        let reducedCopyPreset = copyPreset.map { promptExportCopyPresetMetadataWithoutKind($0) }
        var candidates: [([String: Any], [[String: Any]])] = []
        if let copyPreset {
            var exportObject = coreExportObject
            exportObject["copy_preset"] = copyPreset
            candidates.append((exportObject, cappedFiles))
            candidates.append((exportObject, []))
        }
        if let reducedCopyPreset {
            var exportObject = coreExportObject
            exportObject["copy_preset"] = reducedCopyPreset
            candidates.append((exportObject, []))
        }
        candidates.append((coreExportObject, cappedFiles))
        candidates.append((coreExportObject, []))

        for (exportObject, files) in candidates {
            guard let json = promptExportMetadataJSONString(exportObject: exportObject, files: files),
                  !exceedsPersistedToolSummaryBudget(json) else { continue }
            return json
        }
        return nil
    }

    private static func promptExportMetadataJSONString(
        exportObject: [String: Any],
        files: [[String: Any]]
    ) -> String? {
        var exportObject = exportObject
        exportObject["files"] = files
        return jsonString(from: [
            "op": "export",
            "export": exportObject
        ])
    }

    private static func promptExportCopyPresetMetadata(_ rawCopyPreset: [String: Any]?) -> [String: Any]? {
        guard let rawCopyPreset,
              let id = storageSafeMetadataString(stringValue(rawCopyPreset, keys: ["id"])),
              let name = storageSafeMetadataString(stringValue(rawCopyPreset, keys: ["name"])),
              let isBuiltIn = boolValue(rawCopyPreset, keys: ["is_built_in", "isBuiltIn"])
        else { return nil }
        var copyPreset: [String: Any] = [
            "id": id,
            "name": name,
            "is_built_in": isBuiltIn
        ]
        if let kind = storageSafeMetadataString(stringValue(rawCopyPreset, keys: ["kind"])) {
            copyPreset["kind"] = kind
        }
        return copyPreset
    }

    private static func promptExportCopyPresetMetadataWithoutKind(_ copyPreset: [String: Any]) -> [String: Any] {
        var reduced = copyPreset
        reduced.removeValue(forKey: "kind")
        return reduced
    }

    private static func promptExportFileMetadata(_ rawFiles: [[String: Any]]?, limit: Int) -> [[String: Any]] {
        guard let rawFiles, limit > 0 else { return [] }
        return rawFiles.prefix(limit).compactMap { rawFile in
            guard let path = storageSafeMetadataString(stringValue(rawFile, keys: ["path"])),
                  let tokens = intValue(rawFile, keys: ["tokens"])
            else { return nil }
            var file: [String: Any] = [
                "path": path,
                "tokens": tokens,
                "render_mode": storageSafeMetadataString(stringValue(rawFile, keys: ["render_mode", "renderMode"])) ?? "unknown",
                "is_auto": boolValue(rawFile, keys: ["is_auto", "isAuto"]) ?? false
            ]
            if let codemapOrigin = storageSafeMetadataString(stringValue(rawFile, keys: ["codemap_origin", "codemapOrigin"])) {
                file["codemap_origin"] = codemapOrigin
            }
            if let pathWithinRoot = storageSafeMetadataString(stringValue(rawFile, keys: ["path_within_root", "pathWithinRoot"])) {
                file["path_within_root"] = pathWithinRoot
            }
            return file
        }
    }

    private static func storageSafeCursorACPStructuredSummary(
        _ resultJSON: String?,
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        guard let resultJSON = resultJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !resultJSON.isEmpty,
              let object = jsonObject(from: resultJSON, context: context),
              stringValue(object, keys: ["acp_status"]) != nil
        else { return nil }
        if boolValue(object, keys: ["summary_only", "summaryOnly"]) == true,
           !exceedsPersistedToolSummaryBudget(resultJSON)
        {
            return resultJSON
        }
        return cursorACPSummaryJSON(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            rawObject: object
        )
    }

    static func sanitizeTranscript(_ transcript: AgentTranscript) -> AgentTranscript {
        sanitizeTranscriptWithMetrics(transcript).transcript
    }

    static func sanitizeTranscriptForPersistence(_ transcript: AgentTranscript) -> AgentTranscript {
        sanitizeTranscriptForPersistenceWithMetrics(transcript).transcript
    }

    static func sanitizeTranscriptForPersistenceWithMetrics(
        _ transcript: AgentTranscript,
        context: AgentToolResultProcessingContext? = nil
    ) -> AgentSanitizedTranscriptMetrics {
        sanitizeTranscriptWithMetrics(
            transcript,
            previousSanitizedTranscript: nil,
            reusablePrefixTurnCount: nil,
            preservedVisibleToolResultRowIDs: [],
            context: context,
            purpose: .persistentStorage
        )
    }

    /// `previousRawInputEvidence` describes the build whose sanitized output is
    /// `previousSanitizedTranscript`. When both are supplied for runtime presentation with no
    /// preserved visible rows, the raw-input activity comparison path runs and the prefix and
    /// trusted-suffix hints are ignored.
    package static func sanitizeTranscriptWithMetrics(
        _ transcript: AgentTranscript,
        previousSanitizedTranscript: AgentTranscript? = nil,
        previousRawInputEvidence: AgentSanitizeRawInputEvidence? = nil,
        reusablePrefixTurnCount: Int? = nil,
        trustedReusablePrefixTurnCount: Int? = nil,
        trustedIncrementalFinalTurnStartSequenceIndex: Int? = nil,
        preservedVisibleToolResultRowIDs: Set<UUID>? = nil,
        context: AgentToolResultProcessingContext? = nil,
        purpose: AgentToolResultSanitizationPurpose = .runtimePresentation
    ) -> AgentSanitizedTranscriptMetrics {
        var metrics = sanitizeTranscriptWithMetricsUncaptured(
            transcript,
            previousSanitizedTranscript: previousSanitizedTranscript,
            previousRawInputEvidence: previousRawInputEvidence,
            reusablePrefixTurnCount: reusablePrefixTurnCount,
            trustedReusablePrefixTurnCount: trustedReusablePrefixTurnCount,
            trustedIncrementalFinalTurnStartSequenceIndex: trustedIncrementalFinalTurnStartSequenceIndex,
            preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
            context: context,
            purpose: purpose
        )
        metrics.transcript = AgentRichPresentationCapture.attaching(from: transcript, to: metrics.transcript)
        return metrics
    }

    private static func sanitizeTranscriptWithMetricsUncaptured(
        _ transcript: AgentTranscript,
        previousSanitizedTranscript: AgentTranscript?,
        previousRawInputEvidence: AgentSanitizeRawInputEvidence?,
        reusablePrefixTurnCount: Int?,
        trustedReusablePrefixTurnCount: Int?,
        trustedIncrementalFinalTurnStartSequenceIndex: Int?,
        preservedVisibleToolResultRowIDs: Set<UUID>?,
        context: AgentToolResultProcessingContext?,
        purpose: AgentToolResultSanitizationPurpose
    ) -> AgentSanitizedTranscriptMetrics {
        if purpose == .runtimePresentation,
           (preservedVisibleToolResultRowIDs ?? []).isEmpty,
           let previousRawInputEvidence,
           let previousSanitizedTranscript
        {
            return sanitizeRecordingProcessingFlags(
                transcript,
                reuseSource: RawInputReuseSource(
                    evidence: previousRawInputEvidence,
                    sanitizedTranscript: previousSanitizedTranscript
                ),
                context: context,
                incrementalPathReason: .rawInputActivityComparison
            )
        }
        let reusedTurnCount: Int = switch purpose {
        case .runtimePresentation:
            validatedReusablePrefixTurnCount(
                in: transcript,
                previousSanitizedTranscript: previousSanitizedTranscript,
                requestedPrefixTurnCount: trustedReusablePrefixTurnCount ?? reusablePrefixTurnCount
            )
        case .persistentStorage:
            0
        }
        let incrementalPathReason: AgentSanitizeIncrementalPathReason
        if purpose != .runtimePresentation {
            incrementalPathReason = .notRuntimePresentation
        } else if let trustedIncrementalFinalTurnStartSequenceIndex {
            if let previousSanitizedTranscript {
                if transcript.turns.count != previousSanitizedTranscript.turns.count {
                    incrementalPathReason = .turnCountMismatch
                } else if reusedTurnCount != max(0, transcript.turns.count - 1) {
                    incrementalPathReason = .reusedPrefixMismatch
                } else if let currentFinalTurn = transcript.turns.last,
                          let previousFinalTurn = previousSanitizedTranscript.turns.last
                {
                    if currentFinalTurn.id != previousFinalTurn.id {
                        incrementalPathReason = .finalTurnIdentityMismatch
                    } else {
                        var sanitizedTranscript = transcript
                        switch sanitizeFinalTurnIncrementally(
                            &sanitizedTranscript.turns[sanitizedTranscript.turns.count - 1],
                            previousSanitizedTurn: previousFinalTurn,
                            startingAtSequenceIndex: trustedIncrementalFinalTurnStartSequenceIndex,
                            preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs ?? [],
                            context: context
                        ) {
                        case let .sanitized(sanitizedActivityCount):
                            return AgentSanitizedTranscriptMetrics(
                                transcript: sanitizedTranscript,
                                sanitizedActivityCount: sanitizedActivityCount,
                                reusedTurnCount: reusedTurnCount,
                                incrementalPathReason: .activitySuffixSuccess
                            )
                        case let .rejected(reason):
                            incrementalPathReason = reason
                        }
                    }
                } else {
                    incrementalPathReason = .finalTurnMissing
                }
            } else {
                incrementalPathReason = .previousSanitizedTranscriptUnavailable
            }
        } else {
            incrementalPathReason = .trustedSuffixUnavailable
        }
        if reusedTurnCount == 0, (preservedVisibleToolResultRowIDs ?? []).isEmpty, purpose == .runtimePresentation {
            // Every activity is processed (or processing is skipped wholesale) exactly as by the
            // loop below, additionally recording each processing result.
            return sanitizeRecordingProcessingFlags(
                transcript,
                reuseSource: nil,
                context: context,
                incrementalPathReason: incrementalPathReason
            )
        }
        let containsSanitizableActivities: Bool = switch purpose {
        case .runtimePresentation:
            containsToolResultActivities(in: transcript)
        case .persistentStorage:
            containsToolExecutionActivities(in: transcript)
        }
        guard containsSanitizableActivities else {
            return AgentSanitizedTranscriptMetrics(
                transcript: transcript,
                sanitizedActivityCount: 0,
                reusedTurnCount: reusedTurnCount,
                incrementalPathReason: incrementalPathReason
            )
        }
        let preservedRowIDs: Set<UUID> = switch purpose {
        case .runtimePresentation:
            // The Agent Mode VM projection path stays sanitized and visible cards
            // read retained raw payloads from the ephemeral map at render time.
            // Some pipeline callers may still preserve explicit visible row IDs.
            preservedVisibleToolResultRowIDs ?? []
        case .persistentStorage:
            []
        }
        var sanitizedTranscript = transcript
        if reusedTurnCount > 0, let previousSanitizedTranscript {
            sanitizedTranscript.turns.replaceSubrange(
                0 ..< reusedTurnCount,
                with: previousSanitizedTranscript.turns.prefix(reusedTurnCount)
            )
        }
        var sanitizedActivityCount = 0
        for turnIndex in sanitizedTranscript.turns.indices where turnIndex >= reusedTurnCount {
            sanitizedActivityCount += sanitizeTurn(
                &sanitizedTranscript.turns[turnIndex],
                preservedVisibleToolResultRowIDs: preservedRowIDs,
                context: context,
                purpose: purpose
            )
        }
        return AgentSanitizedTranscriptMetrics(
            transcript: sanitizedTranscript,
            sanitizedActivityCount: sanitizedActivityCount,
            reusedTurnCount: reusedTurnCount,
            incrementalPathReason: incrementalPathReason
        )
    }

    private struct RawInputReuseSource {
        let evidence: AgentSanitizeRawInputEvidence
        let sanitizedTranscript: AgentTranscript

        func sanitizedTurn(at turnIndex: Int, id turnID: UUID) -> AgentTranscriptTurn? {
            guard sanitizedTranscript.turns.indices.contains(turnIndex),
                  sanitizedTranscript.turns[turnIndex].id == turnID
            else {
                return nil
            }
            return sanitizedTranscript.turns[turnIndex]
        }

        /// Previous raw activities, outputs, and processing flags for the span at the same
        /// turn/span position, when every identity and length aligns.
        func candidates(turnIndex: Int, turnID: UUID, spanIndex: Int, spanID: UUID) -> RawInputReuseCandidates? {
            let rawTurns = evidence.importedTranscript.turns
            let flagTurns = evidence.activityProcessingFlags
            let sanitizedTurns = sanitizedTranscript.turns
            guard rawTurns.indices.contains(turnIndex),
                  sanitizedTurns.indices.contains(turnIndex),
                  flagTurns.indices.contains(turnIndex)
            else {
                return nil
            }
            let rawTurn = rawTurns[turnIndex]
            let sanitizedTurn = sanitizedTurns[turnIndex]
            let flagSpans = flagTurns[turnIndex]
            guard rawTurn.id == turnID,
                  sanitizedTurn.id == turnID,
                  rawTurn.responseSpans.count == flagSpans.count,
                  rawTurn.responseSpans.indices.contains(spanIndex),
                  sanitizedTurn.responseSpans.indices.contains(spanIndex)
            else {
                return nil
            }
            let rawSpan = rawTurn.responseSpans[spanIndex]
            let sanitizedSpan = sanitizedTurn.responseSpans[spanIndex]
            let flags = flagSpans[spanIndex]
            guard rawSpan.id == spanID,
                  sanitizedSpan.id == spanID,
                  rawSpan.activities.count == sanitizedSpan.activities.count,
                  rawSpan.activities.count == flags.count
            else {
                return nil
            }
            return RawInputReuseCandidates(
                previousRawActivities: rawSpan.activities,
                previousSanitizedActivities: sanitizedSpan.activities,
                previousProcessingFlags: flags
            )
        }
    }

    /// Runtime sanitize (no preserved rows) that records, for every activity, the Boolean that
    /// processing returned. With a reuse source, an activity whose raw input fully equals the
    /// previous raw input at the same turn/span/activity position (identities aligned across
    /// previous input, output, and flags) installs the previous output and replays its recorded
    /// flag and context registration instead of being processed, so mutation counts,
    /// grouped-history cache invalidation, and context state match processing it. Turn and span
    /// metadata always come from the current input.
    private static func sanitizeRecordingProcessingFlags(
        _ transcript: AgentTranscript,
        reuseSource: RawInputReuseSource?,
        context: AgentToolResultProcessingContext?,
        incrementalPathReason: AgentSanitizeIncrementalPathReason
    ) -> AgentSanitizedTranscriptMetrics {
        guard containsToolResultActivities(in: transcript) else {
            // Processing is skipped wholesale. With no tool-kind activity at all, processing each
            // activity would also report false, so all-false flags are exact. Tool calls without
            // results are left unprocessed here but would be normalized later; record nothing.
            return AgentSanitizedTranscriptMetrics(
                transcript: transcript,
                sanitizedActivityCount: 0,
                reusedTurnCount: 0,
                incrementalPathReason: incrementalPathReason,
                activityProcessingFlags: containsToolKindActivities(in: transcript)
                    ? nil
                    : transcript.turns.map { $0.responseSpans.map { Array(repeating: false, count: $0.activities.count) } }
            )
        }
        var sanitizedTranscript = transcript
        var sanitizedActivityCount = 0
        var reusedActivityCount = 0
        var reusedTurnCount = 0
        var flagsByTurn: [[[Bool]]] = []
        flagsByTurn.reserveCapacity(sanitizedTranscript.turns.count)
        for turnIndex in sanitizedTranscript.turns.indices {
            let turnID = sanitizedTranscript.turns[turnIndex].id
            var turnReusedActivityCount = 0
            var flagsBySpan: [[Bool]] = []
            flagsBySpan.reserveCapacity(sanitizedTranscript.turns[turnIndex].responseSpans.count)
            for spanIndex in sanitizedTranscript.turns[turnIndex].responseSpans.indices {
                let candidates = reuseSource?.candidates(
                    turnIndex: turnIndex,
                    turnID: turnID,
                    spanIndex: spanIndex,
                    spanID: sanitizedTranscript.turns[turnIndex].responseSpans[spanIndex].id
                )
                let result = sanitizeActivitiesRecordingProcessingFlags(
                    in: &sanitizedTranscript.turns[turnIndex].responseSpans[spanIndex],
                    candidates: candidates,
                    context: context
                )
                sanitizedActivityCount += result.sanitized
                reusedActivityCount += result.reused
                turnReusedActivityCount += result.reused
                flagsBySpan.append(result.flags)
            }
            flagsByTurn.append(flagsBySpan)
            // A leading turn whose every tool activity was reused (non-tool activities are never
            // candidates; processing them is a no-op) and whose sanitized result equals the
            // previous output turn apart from grouped-history refresh state (span caches and the
            // turn's frozen tail limit) takes the previous spans, keeping their grouped caches,
            // with its own frozen limit. The reported reusable prefix lets the cache refresh
            // validate those caches and keep them instead of rebuilding, as for legacy prefixes.
            if reusedTurnCount == turnIndex,
               let previousTurn = reuseSource?.sanitizedTurn(at: turnIndex, id: turnID),
               turnReusedActivityCount == toolKindActivityCount(in: sanitizedTranscript.turns[turnIndex])
            {
                var installedTurn = previousTurn
                installedTurn.frozenDetailedToolTailLimit = sanitizedTranscript.turns[turnIndex].frozenDetailedToolTailLimit
                // Span equality excludes grouped caches.
                if installedTurn == sanitizedTranscript.turns[turnIndex] {
                    sanitizedTranscript.turns[turnIndex] = installedTurn
                    reusedTurnCount += 1
                }
            }
        }
        return AgentSanitizedTranscriptMetrics(
            transcript: sanitizedTranscript,
            sanitizedActivityCount: sanitizedActivityCount,
            reusedTurnCount: reusedTurnCount,
            incrementalPathReason: incrementalPathReason,
            reusedActivityCount: reusedActivityCount,
            activityProcessingFlags: flagsByTurn
        )
    }

    private static func toolKindActivityCount(in turn: AgentTranscriptTurn) -> Int {
        turn.responseSpans.reduce(0) { count, span in
            count + span.activities.count { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
        }
    }

    private static func containsToolKindActivities(in transcript: AgentTranscript) -> Bool {
        transcript.turns.contains { turn in
            turn.responseSpans.contains { span in
                span.activities.contains { $0.itemKind == .toolCall || $0.itemKind == .toolResult }
            }
        }
    }

    private struct RawInputReuseCandidates {
        let previousRawActivities: [AgentTranscriptActivity]
        let previousSanitizedActivities: [AgentTranscriptActivity]
        let previousProcessingFlags: [Bool]

        /// The previous output and recorded processing flag for `activity` when processing it
        /// provably reproduces them: a tool activity carrying its own execution (so processing
        /// never consults the context's per-ID execution state) whose raw input fully equals the
        /// previous raw input at this position.
        func reusableResult(
            at index: Int,
            for activity: AgentTranscriptActivity
        ) -> (activity: AgentTranscriptActivity, execution: AgentTranscriptToolExecution, flag: Bool)? {
            guard activity.itemKind == .toolCall || activity.itemKind == .toolResult,
                  activity.toolExecution != nil,
                  previousRawActivities.indices.contains(index)
            else {
                return nil
            }
            let previousSanitized = previousSanitizedActivities[index]
            let flag = previousProcessingFlags[index]
            guard previousSanitized.id == activity.id,
                  let execution = previousSanitized.toolExecution,
                  previousRawActivities[index] == activity,
                  // An unprocessed (false) result leaves the activity untouched.
                  flag || previousSanitized == activity
            else {
                return nil
            }
            return (previousSanitized, execution, flag)
        }
    }

    private static func sanitizeActivitiesRecordingProcessingFlags(
        in span: inout AgentTranscriptProviderResponseSpan,
        candidates: RawInputReuseCandidates?,
        context: AgentToolResultProcessingContext?
    ) -> (sanitized: Int, reused: Int, flags: [Bool]) {
        var sanitizedActivityCount = 0
        var reusedActivityCount = 0
        var spanDidMutate = false
        var flags: [Bool] = []
        flags.reserveCapacity(span.activities.count)
        for activityIndex in span.activities.indices {
            let didMutate: Bool
            if let reused = candidates?.reusableResult(at: activityIndex, for: span.activities[activityIndex]) {
                // Processing an execution-carrying tool activity last registers exactly the
                // output's execution for its ID; replay that at the same traversal position.
                context?.storeToolExecution(reused.execution, for: reused.activity.id)
                span.activities[activityIndex] = reused.activity
                reusedActivityCount += 1
                didMutate = reused.flag
            } else {
                didMutate = sanitizeActivity(
                    &span.activities[activityIndex],
                    preservedVisibleToolResultRowIDs: [],
                    context: context,
                    purpose: .runtimePresentation
                )
            }
            flags.append(didMutate)
            if didMutate {
                spanDidMutate = true
                sanitizedActivityCount += 1
            }
        }
        if spanDidMutate {
            span.fullRenderGroupedHistoryCache = nil
        }
        return (sanitizedActivityCount, reusedActivityCount, flags)
    }

    private enum IncrementalFinalTurnSanitizeOutcome {
        case sanitized(Int)
        case rejected(AgentSanitizeIncrementalPathReason)
    }

    private static func sanitizeFinalTurnIncrementally(
        _ turn: inout AgentTranscriptTurn,
        previousSanitizedTurn: AgentTranscriptTurn,
        startingAtSequenceIndex: Int,
        preservedVisibleToolResultRowIDs: Set<UUID>,
        context: AgentToolResultProcessingContext?
    ) -> IncrementalFinalTurnSanitizeOutcome {
        guard turn.request?.id == previousSanitizedTurn.request?.id else {
            return .rejected(.requestMismatch)
        }
        guard turn.responseSpans.count == previousSanitizedTurn.responseSpans.count else {
            return .rejected(.spanCountMismatch)
        }

        var updatedTurn = turn
        var reachedChangedSuffix = false
        var sanitizedActivityCount = 0

        for spanIndex in updatedTurn.responseSpans.indices {
            let currentSpan = turn.responseSpans[spanIndex]
            let previousSpan = previousSanitizedTurn.responseSpans[spanIndex]
            guard currentSpan.id == previousSpan.id else { return .rejected(.spanIdentityMismatch) }

            if !reachedChangedSuffix {
                let changedActivityIndex = lowerBoundActivityIndex(
                    in: currentSpan.activities,
                    sequenceIndex: startingAtSequenceIndex
                )
                if changedActivityIndex == currentSpan.activities.count {
                    guard currentSpan.activities.count == previousSpan.activities.count,
                          currentSpan.activities.first?.id == previousSpan.activities.first?.id,
                          currentSpan.activities.last?.id == previousSpan.activities.last?.id
                    else {
                        return .rejected(.unchangedSpanMismatch)
                    }
                    updatedTurn.responseSpans[spanIndex].activities = previousSpan.activities
                    continue
                }

                guard changedActivityIndex <= previousSpan.activities.count else {
                    return .rejected(.changedActivityIndexOutOfRange)
                }
                if changedActivityIndex > 0 {
                    guard currentSpan.activities[changedActivityIndex - 1].id
                        == previousSpan.activities[changedActivityIndex - 1].id
                    else {
                        return .rejected(.prefixBoundaryMismatch)
                    }
                }

                var mergedActivities = previousSpan.activities
                mergedActivities.replaceSubrange(
                    changedActivityIndex ..< mergedActivities.count,
                    with: currentSpan.activities[changedActivityIndex...]
                )
                updatedTurn.responseSpans[spanIndex].activities = mergedActivities
                sanitizedActivityCount += sanitizeActivities(
                    in: &updatedTurn.responseSpans[spanIndex],
                    startingAt: changedActivityIndex,
                    preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
                    context: context,
                    purpose: .runtimePresentation
                )
                reachedChangedSuffix = true
                continue
            }

            sanitizedActivityCount += sanitizeActivities(
                in: &updatedTurn.responseSpans[spanIndex],
                startingAt: 0,
                preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
                context: context,
                purpose: .runtimePresentation
            )
        }

        guard reachedChangedSuffix else { return .rejected(.changedSuffixNotFound) }
        turn = updatedTurn
        return .sanitized(sanitizedActivityCount)
    }

    private static func lowerBoundActivityIndex(
        in activities: [AgentTranscriptActivity],
        sequenceIndex: Int
    ) -> Int {
        var lowerBound = activities.startIndex
        var upperBound = activities.endIndex
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if activities[midpoint].sequenceIndex < sequenceIndex {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }

    private static func validatedReusablePrefixTurnCount(
        in transcript: AgentTranscript,
        previousSanitizedTranscript: AgentTranscript?,
        requestedPrefixTurnCount: Int?
    ) -> Int {
        guard let previousSanitizedTranscript else { return 0 }
        let availablePrefixTurnCount = min(transcript.turns.count, previousSanitizedTranscript.turns.count)
        guard availablePrefixTurnCount > 0 else { return 0 }
        let candidatePrefixTurnCount = min(requestedPrefixTurnCount ?? availablePrefixTurnCount, availablePrefixTurnCount)
        guard candidatePrefixTurnCount > 0 else { return 0 }
        var reusableTurnCount = 0
        for index in 0 ..< candidatePrefixTurnCount {
            let currentTurn = transcript.turns[index]
            let previousTurn = previousSanitizedTranscript.turns[index]
            guard currentTurn == previousTurn else {
                break
            }
            reusableTurnCount += 1
        }
        return reusableTurnCount
    }

    private static func containsToolResultActivities(in transcript: AgentTranscript) -> Bool {
        for turn in transcript.turns {
            for span in turn.responseSpans {
                if span.activities.contains(where: { $0.itemKind == .toolResult }) {
                    return true
                }
            }
        }
        return false
    }

    private static func containsToolExecutionActivities(in transcript: AgentTranscript) -> Bool {
        for turn in transcript.turns {
            for span in turn.responseSpans {
                if span.activities.contains(where: { $0.toolExecution != nil || $0.itemKind == .toolCall || $0.itemKind == .toolResult }) {
                    return true
                }
            }
        }
        return false
    }

    @discardableResult
    private static func sanitizeTurn(
        _ turn: inout AgentTranscriptTurn,
        preservedVisibleToolResultRowIDs: Set<UUID>,
        context: AgentToolResultProcessingContext?,
        purpose: AgentToolResultSanitizationPurpose
    ) -> Int {
        var sanitizedActivityCount = 0
        for spanIndex in turn.responseSpans.indices {
            sanitizedActivityCount += sanitizeActivities(
                in: &turn.responseSpans[spanIndex],
                startingAt: 0,
                preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
                context: context,
                purpose: purpose
            )
        }
        return sanitizedActivityCount
    }

    private static func sanitizeActivities(
        in span: inout AgentTranscriptProviderResponseSpan,
        startingAt startIndex: Int,
        preservedVisibleToolResultRowIDs: Set<UUID>,
        context: AgentToolResultProcessingContext?,
        purpose: AgentToolResultSanitizationPurpose
    ) -> Int {
        guard startIndex < span.activities.count else { return 0 }
        var sanitizedActivityCount = 0
        var spanDidMutate = false
        for activityIndex in startIndex ..< span.activities.count {
            guard sanitizeActivity(
                &span.activities[activityIndex],
                preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
                context: context,
                purpose: purpose
            ) else {
                continue
            }
            spanDidMutate = true
            sanitizedActivityCount += 1
        }
        if spanDidMutate {
            span.fullRenderGroupedHistoryCache = nil
        }
        return sanitizedActivityCount
    }

    /// Normalizes and sanitizes one activity; writes it back and returns true only when
    /// processing reported a mutation.
    private static func sanitizeActivity(
        _ target: inout AgentTranscriptActivity,
        preservedVisibleToolResultRowIDs: Set<UUID>,
        context: AgentToolResultProcessingContext?,
        purpose: AgentToolResultSanitizationPurpose
    ) -> Bool {
        var activity = target
        let didNormalizeToolIdentity = normalizeToolIdentity(&activity, context: context)
        let didSanitize: Bool = switch purpose {
        case .runtimePresentation:
            sanitizeRuntimeActivity(
                &activity,
                preservedVisibleToolResultRowIDs: preservedVisibleToolResultRowIDs,
                context: context
            )
        case .persistentStorage:
            sanitizePersistentStorageActivity(&activity, context: context)
        }
        guard didNormalizeToolIdentity || didSanitize else { return false }
        target = activity
        return true
    }

    private static func normalizeToolIdentity(
        _ activity: inout AgentTranscriptActivity,
        context: AgentToolResultProcessingContext?
    ) -> Bool {
        guard activity.itemKind == .toolCall || activity.itemKind == .toolResult else { return false }
        let originalActivity = activity
        let sourceItem = activity.toItem()
        let execution = activity.toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: sourceItem, context: context)
        guard var updatedExecution = execution else { return false }
        let rawToolName = updatedExecution.toolName ?? sourceItem.toolName
        if let normalizedToolName = AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(rawToolName),
           !normalizedToolName.isEmpty
        {
            updatedExecution.toolName = normalizedToolName
        }
        if let pathSignal = AgentTranscriptToolVisibilityPolicy.pathSignal(fromPathLikeToolName: rawToolName),
           !updatedExecution.keyPaths.contains(pathSignal)
        {
            updatedExecution.keyPaths.insert(pathSignal, at: 0)
        }
        activity.toolExecution = updatedExecution
        context?.storeToolExecution(updatedExecution, for: activity.id)
        return activity != originalActivity
    }

    private static func sanitizeRuntimeActivity(
        _ activity: inout AgentTranscriptActivity,
        preservedVisibleToolResultRowIDs: Set<UUID>,
        context: AgentToolResultProcessingContext?
    ) -> Bool {
        guard activity.itemKind == .toolResult else { return false }
        guard !preservedVisibleToolResultRowIDs.contains(activity.id) else { return false }
        let item = activity.toItem()
        guard let sanitized = sanitizedToolResult(for: item, toolExecution: activity.toolExecution, context: context) else { return false }
        let generatedExecution = activity.toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
        guard var updatedExecution = generatedExecution else { return false }
        updatedExecution.resultJSON = sanitized.resultJSON
        updatedExecution.toolIsError = sanitized.toolIsError
        updatedExecution.status = sanitized.transcriptStatus
        updatedExecution.summaryOnly = sanitized.summaryOnly
        updatedExecution.processID = sanitized.processID
        updatedExecution.exitCode = sanitized.exitCode
        context?.storeToolExecution(updatedExecution, for: activity.id)
        activity.text = sanitized.text
        activity.toolExecution = updatedExecution
        return true
    }

    private static func sanitizePersistentStorageActivity(
        _ activity: inout AgentTranscriptActivity,
        context: AgentToolResultProcessingContext?
    ) -> Bool {
        guard activity.toolExecution != nil || activity.itemKind == .toolCall || activity.itemKind == .toolResult else { return false }
        let item = activity.toItem()
        let generatedExecution = activity.toolExecution ?? AgentTranscriptToolNormalizer.toolExecution(for: item, context: context)
        guard var updatedExecution = generatedExecution else { return false }
        let originalActivity = activity
        let normalizedToolName = normalizedToolName(updatedExecution.toolName ?? item.toolName)
        var persistentSummaryOnly = true

        if activity.itemKind == .toolResult,
           let persistedSummary = persistedToolResultSummary(
               for: item,
               toolExecution: updatedExecution,
               rawResultTextFallback: activity.text,
               context: context
           )
        {
            updatedExecution.resultJSON = persistedSummary.resultJSON
            updatedExecution.toolIsError = persistedSummary.toolIsError
            updatedExecution.status = persistedSummary.transcriptStatus
            updatedExecution.processID = persistedSummary.processID
            updatedExecution.exitCode = persistedSummary.exitCode
            updatedExecution.summaryText = persistedSummary.summaryText
            persistentSummaryOnly = persistedSummary.summaryOnly
            activity.text = persistedSummary.resultJSON
        } else if activity.itemKind == .toolResult {
            let statusWord = AgentTranscriptToolStatusSemantics.persistedStatusWord(from: updatedExecution.status)
            let summaryText = storageSafeSummaryText(
                normalizedToolName: normalizedToolName,
                toolName: updatedExecution.toolName ?? item.toolName,
                status: updatedExecution.status,
                rawResultJSONCandidates: [updatedExecution.resultJSON, item.toolResultJSON, activity.text],
                argsJSON: item.toolArgsJSON,
                context: context
            )
            let renderSummary = storageSafeRenderSummary(
                normalizedToolName: normalizedToolName,
                statusWord: statusWord,
                rawResultJSONCandidates: [updatedExecution.resultJSON, item.toolResultJSON, activity.text],
                argsJSON: item.toolArgsJSON ?? updatedExecution.argsJSON,
                context: context,
                allowExistingSummaryOnly: updatedExecution.summaryOnly
            )
            let minimalJSON = minimalResultJSON(
                statusWord: statusWord,
                normalizedToolName: normalizedToolName,
                processID: storageSafeMetadataString(updatedExecution.processID),
                exitCode: updatedExecution.exitCode,
                summaryText: renderSummary?.inlineSummaryText ?? summaryText,
                renderSummary: renderSummary
            )
            updatedExecution.resultJSON = minimalJSON
            updatedExecution.summaryText = summaryText
            activity.text = minimalJSON
        } else {
            updatedExecution.resultJSON = nil
            updatedExecution.summaryText = storageSafeSummaryText(
                normalizedToolName: normalizedToolName,
                toolName: updatedExecution.toolName ?? item.toolName,
                status: updatedExecution.status,
                rawResultJSONCandidates: [],
                argsJSON: nil,
                context: context
            )
            activity.text = sanitizedToolCallText(toolName: updatedExecution.toolName ?? item.toolName)
        }

        let preservesCompleteExchange = activity.itemKind == .toolResult
            && !persistentSummaryOnly
            && normalizedToolName.map(completeExchangeToolNames.contains) == true
        updatedExecution.argsJSON = preservesCompleteExchange ? (updatedExecution.argsJSON ?? item.toolArgsJSON) : nil
        updatedExecution.summaryOnly = persistentSummaryOnly
        updatedExecution.keyPaths = []
        enforcePersistentPayloadCap(
            activity: &activity,
            execution: &updatedExecution,
            normalizedToolName: normalizedToolName,
            preservesCompleteExchange: preservesCompleteExchange
        )
        activity.toolExecution = updatedExecution
        context?.storeToolExecution(updatedExecution, for: activity.id)
        return activity != originalActivity
    }

    private static func enforcePersistentPayloadCap(
        activity: inout AgentTranscriptActivity,
        execution: inout AgentTranscriptToolExecution,
        normalizedToolName: String?,
        preservesCompleteExchange: Bool
    ) {
        execution.processID = storageSafeMetadataString(execution.processID)
        execution.summaryText = smallStorageSummaryText(execution.summaryText)
        if exceedsCommittedMetadataLimit(execution.toolName) {
            execution.toolName = storageSafeMetadataString(normalizedToolName) ?? "tool"
        }
        guard !preservesCompleteExchange else { return }

        let statusWord = AgentTranscriptToolStatusSemantics.persistedStatusWord(from: execution.status)
        let fallbackWithMetadata = minimalResultJSON(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: execution.processID,
            exitCode: execution.exitCode,
            summaryText: execution.summaryText
        )
        let fallbackJSON = exceedsPersistedToolSummaryBudget(fallbackWithMetadata)
            ? minimalResultJSON(statusWord: statusWord, normalizedToolName: normalizedToolName)
            : fallbackWithMetadata

        if exceedsPersistedToolSummaryBudget(activity.text) {
            activity.text = fallbackJSON
        }
        if let resultJSON = execution.resultJSON,
           exceedsPersistedToolSummaryBudget(resultJSON)
        {
            execution.resultJSON = fallbackJSON
            if activity.itemKind == .toolResult {
                activity.text = fallbackJSON
            }
        }
        if let argsJSON = execution.argsJSON,
           exceedsPersistedToolSummaryBudget(argsJSON)
        {
            execution.argsJSON = nil
        }
        if let summaryText = execution.summaryText,
           exceedsPersistedToolSummaryBudget(summaryText)
        {
            execution.summaryText = smallStorageSummaryText(summaryText)
        }
    }

    private static func storageSafeMetadataString(_ value: String?) -> String? {
        guard let value = trimmedStorageString(value) else { return nil }
        return value.utf8.count <= 512 ? value : nil
    }

    private static func exceedsCommittedMetadataLimit(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.utf8.count > 512
    }

    private static func exceedsPersistedToolSummaryBudget(_ value: String) -> Bool {
        value.utf8.count > maxPersistedToolSummaryBytes
    }

    static func sanitizedToolCallText(toolName: String?) -> String {
        let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return "Using tool" }
        return "Using tool: \(name)"
    }

    static func storageSafeSummaryText(toolName: String?, status: AgentTranscriptToolStatus) -> String {
        storageSafeSummaryText(
            normalizedToolName: normalizedToolName(toolName),
            toolName: toolName,
            status: status,
            rawResultJSONCandidates: [],
            argsJSON: nil,
            context: nil
        )
    }

    private static func storageSafeSummaryText(
        normalizedToolName: String?,
        toolName: String?,
        status: AgentTranscriptToolStatus,
        rawResultJSONCandidates: [String?],
        argsJSON: String?,
        context: AgentToolResultProcessingContext?
    ) -> String {
        let statusWord = AgentTranscriptToolStatusSemantics.persistedStatusWord(from: status)
        if let renderSummary = storageSafeRenderSummary(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            rawResultJSONCandidates: rawResultJSONCandidates,
            argsJSON: argsJSON,
            context: context,
            allowExistingSummaryOnly: false
        ), let inlineSummary = renderSummary.inlineSummaryText {
            return inlineSummary
        }
        if normalizedToolName == "git" {
            let argsObject = jsonObject(from: argsJSON, context: context)
            for rawResultJSON in rawResultJSONCandidates {
                guard let summary = gitStorageSummaryText(
                    rawObject: jsonObject(from: rawResultJSON, context: context),
                    argsObject: argsObject
                ) else { continue }
                return summary
            }
            if let summary = gitStorageSummaryText(rawObject: nil, argsObject: argsObject) {
                return summary
            }
        }
        let name = toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (name?.isEmpty == false) ? name ?? "tool" : "tool"
        return "\(displayName) • \(status.rawValue)"
    }

    /// Synthetic remote terminal settlement markers are intentionally embedded in the JSON
    /// payload instead of tracked only in memory so an immediate running update can identify
    /// and reverse only client-stamped settlements. Accepted limitation: AgentChatItemPersist
    /// sanitizes .toolCall persistence by dropping toolResultJSON, so this marker does not
    /// survive a sanitized app-restart round trip.
    private static let syntheticSettlementMarkerKey = "synthetic_settlement"

    package static func syntheticSettlementResultJSON(
        statusWord: String,
        normalizedToolName: String? = nil
    ) -> String {
        let minimalJSON = minimalResultJSON(statusWord: statusWord, normalizedToolName: normalizedToolName)
        var object = jsonObject(from: minimalJSON) ?? [:]
        object[syntheticSettlementMarkerKey] = true
        return jsonString(from: object) ?? minimalJSON
    }

    package static func isSyntheticSettlementJSON(_ json: String?) -> Bool {
        boolValue(jsonObject(from: json), keys: [syntheticSettlementMarkerKey]) == true
    }

    static func minimalResultJSON(
        statusWord: String,
        normalizedToolName: String? = nil,
        processID: String? = nil,
        exitCode: Int? = nil,
        summaryText: String? = nil,
        renderSummary: AgentToolCardRenderSummary? = nil
    ) -> String {
        var object = minimalResultObject(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: processID,
            exitCode: exitCode,
            summaryText: summaryText,
            renderSummary: renderSummary
        )
        if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
            return json
        }
        if let renderSummary, renderSummary.detailText != nil {
            let shortened = renderSummary.withoutDetailText()
            object = minimalResultObject(
                statusWord: statusWord,
                normalizedToolName: normalizedToolName,
                processID: processID,
                exitCode: exitCode,
                summaryText: shortened.inlineSummaryText ?? summaryText,
                renderSummary: shortened
            )
            if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
                return json
            }
        }
        object = minimalResultObject(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: processID,
            exitCode: exitCode,
            summaryText: summaryText,
            renderSummary: nil
        )
        if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
            return json
        }
        object = minimalResultObject(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            processID: processID,
            exitCode: exitCode,
            summaryText: nil,
            renderSummary: nil
        )
        return jsonString(from: object) ?? #"{"status":"unknown","summary_only":true}"#
    }

    private static func minimalResultObject(
        statusWord: String,
        normalizedToolName: String?,
        processID: String?,
        exitCode: Int?,
        summaryText: String?,
        renderSummary: AgentToolCardRenderSummary?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "status": statusWord,
            "summary_only": true
        ]
        if normalizedToolName == "bash" {
            object["type"] = "commandExecution"
        }
        if let processID, !processID.isEmpty {
            object["processId"] = processID
        }
        if let exitCode {
            object["exitCode"] = exitCode
        }
        if let summaryText = smallStorageSummaryText(summaryText) {
            object["summary_text"] = summaryText
        }
        if let renderSummary {
            object["render_summary"] = renderSummary.dictionary
        }
        return object
    }

    private static func gitStorageSummaryText(rawObject: [String: Any]?, argsObject: [String: Any]?) -> String? {
        if let existingSummary = existingGitSummaryOnlyText(rawObject) {
            return existingSummary
        }
        if boolValue(rawObject, keys: ["summary_only", "summaryOnly"]) == true {
            return nil
        }
        guard rawObject != nil || argsObject != nil else { return nil }
        let op = trimmedStorageString(stringValue(rawObject, keys: ["op"]))
            ?? trimmedStorageString(stringValue(argsObject, keys: ["op"]))
            ?? "git"
        let subtitle: String
        let detailText: String?
        switch op.lowercased() {
        case "status":
            subtitle = joinStorageSummary(op, gitStatusPrimarySummary(rawObject: rawObject))
            detailText = gitStatusDetailText(rawObject: rawObject)
        case "diff":
            subtitle = joinStorageSummary(op, gitPreferredDiffSummary(rawObject: rawObject))
            detailText = gitDiffDetailText(rawObject: rawObject, argsObject: argsObject)
        case "log":
            subtitle = joinStorageSummary(op, gitLogSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = nil
        case "show":
            subtitle = joinStorageSummary(op, gitShowSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = nil
        case "blame":
            subtitle = joinStorageSummary(op, gitBlameSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = nil
        default:
            subtitle = joinStorageSummary(op, gitPreferredDiffSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = nil
        }
        return inlineStorageSummary(subtitle, detailText)
    }

    private static func storageSafeRenderSummary(
        normalizedToolName: String?,
        statusWord: String,
        rawResultJSONCandidates: [String?],
        argsJSON: String?,
        context: AgentToolResultProcessingContext?,
        allowExistingSummaryOnly: Bool = false
    ) -> AgentToolCardRenderSummary? {
        let argsObject = jsonObject(from: argsJSON, context: context)
        for rawResultJSON in rawResultJSONCandidates {
            let rawObject = jsonObject(from: rawResultJSON, context: context)
            guard rawObject != nil else { continue }
            if let summary = AgentToolCardRenderSummaryBuilder.build(
                normalizedToolName: normalizedToolName,
                statusWord: statusWord,
                rawObject: rawObject,
                argsObject: argsObject,
                allowExistingSummaryOnly: allowExistingSummaryOnly
            ) {
                return summary
            }
        }
        return AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            rawObject: nil,
            argsObject: argsObject,
            allowExistingSummaryOnly: false
        )
    }

    private static func existingGitSummaryOnlyText(_ rawObject: [String: Any]?) -> String? {
        guard boolValue(rawObject, keys: ["summary_only", "summaryOnly"]) == true else { return nil }
        return smallStorageSummaryText(stringValue(rawObject, keys: ["summary_text", "summaryText"]))
    }

    private static func gitStatusPrimarySummary(rawObject: [String: Any]?) -> String? {
        let status = rawObject?["status"] as? [String: Any]
        return trimmedStorageString(stringValue(status, keys: ["branch"]))
            ?? gitRepoCountText(rawObject: rawObject)
    }

    private static func gitStatusDetailText(rawObject: [String: Any]?) -> String? {
        guard let status = rawObject?["status"] as? [String: Any] else { return nil }
        var parts: [String] = []
        let ahead = intValue(status, keys: ["ahead"])
        let behind = intValue(status, keys: ["behind"])
        if let ahead, let behind, ahead > 0 || behind > 0 {
            parts.append("+\(ahead) -\(behind)")
        }
        if let upstream = trimmedStorageString(stringValue(status, keys: ["upstream"])) {
            parts.append(upstream)
        }
        appendArrayCountSummary(&parts, object: status, key: "staged", label: "staged")
        appendArrayCountSummary(&parts, object: status, key: "modified", label: "modified")
        appendArrayCountSummary(&parts, object: status, key: "untracked", label: "untracked")
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func gitDiffDetailText(rawObject: [String: Any]?, argsObject: [String: Any]?) -> String? {
        let inputs = rawObject?["inputs"] as? [String: Any]
        let diff = rawObject?["diff"] as? [String: Any]
        let worktree = rawObject?["worktree"] as? [String: Any]
        var parts: [String] = []
        if let compare = trimmedStorageString(stringValue(inputs, keys: ["compare"]) ?? stringValue(argsObject, keys: ["compare"])) {
            parts.append(compare)
        }
        if let scope = trimmedStorageString(stringValue(inputs, keys: ["scope"])) {
            parts.append(scope)
        }
        if let detail = trimmedStorageString(stringValue(diff, keys: ["detail"]) ?? stringValue(argsObject, keys: ["detail"])) {
            parts.append(detail)
        }
        if parts.count < 3,
           let branch = trimmedStorageString(stringValue(worktree, keys: ["worktree_branch"]))
        {
            parts.append(branch)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func gitPreferredDiffSummary(rawObject: [String: Any]?) -> String? {
        let aggregate = rawObject?["aggregate"] as? [String: Any]
        let diff = rawObject?["diff"] as? [String: Any]
        let summary = rawObject?["summary"] as? [String: Any]
        return gitTotalsSummaryText(object: aggregate?["totals"] as? [String: Any])
            ?? gitTotalsSummaryText(object: diff?["totals"] as? [String: Any])
            ?? gitTotalsSummaryText(object: summary)
            ?? safeGitDiffOneliner(stringValue(aggregate, keys: ["oneliner"]))
            ?? safeGitDiffOneliner(stringValue(diff, keys: ["oneliner"]))
            ?? safeGitDiffOneliner(stringValue(rawObject, keys: ["oneliner"]))
    }

    private static func safeGitDiffOneliner(_ value: String?) -> String? {
        guard let value = trimmedStorageString(value) else { return nil }
        let lowered = value.lowercased()
        guard !lowered.contains("diff --"),
              !lowered.contains("@@"),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\n"),
              !value.contains("+++"),
              !value.contains("---")
        else { return nil }
        if lowered == "no changes" { return value }
        let pattern = #"^(?:[0-9]+ repos?: )?[0-9]+ files? \(\+[0-9]+ -[0-9]+\)$"#
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: value, range: range) != nil ? value : nil
    }

    private static func gitTotalsSummaryText(object: [String: Any]?) -> String? {
        guard let files = intValue(object, keys: ["files"]),
              let insertions = intValue(object, keys: ["insertions"]),
              let deletions = intValue(object, keys: ["deletions"])
        else { return nil }
        return "\(files) files (+\(insertions) -\(deletions))"
    }

    private static func gitLogSummary(rawObject: [String: Any]?) -> String? {
        guard let log = rawObject?["log"] as? [String: Any],
              let commits = log["commits"] as? [[String: Any]]
        else { return nil }
        if commits.count == 1,
           let first = commits.first,
           let shortSHA = trimmedStorageString(stringValue(first, keys: ["short_sha", "shortSha"]))
        {
            return shortSHA
        }
        return "\(commits.count) commits"
    }

    private static func gitShowSummary(rawObject: [String: Any]?) -> String? {
        guard let show = rawObject?["show"] as? [String: Any] else { return nil }
        return trimmedStorageString(stringValue(show, keys: ["short_sha", "shortSha"]))
    }

    private static func gitBlameSummary(rawObject: [String: Any]?) -> String? {
        guard let blame = rawObject?["blame"] as? [String: Any],
              let lines = blame["lines"] as? [Any]
        else { return nil }
        return "\(lines.count) lines"
    }

    private static func gitRepoCountText(rawObject: [String: Any]?) -> String? {
        guard let repos = rawObject?["repos"] as? [[String: Any]], repos.count > 1 else { return nil }
        return "\(repos.count) repos"
    }

    private static func appendArrayCountSummary(_ parts: inout [String], object: [String: Any], key: String, label: String) {
        guard let array = object[key] as? [Any], !array.isEmpty else { return }
        parts.append("\(array.count) \(label)")
    }

    private static func inlineStorageSummary(_ primary: String?, _ secondary: String?) -> String? {
        let parts = [primary, secondary]
            .compactMap { trimmedStorageString($0) }
        guard !parts.isEmpty else { return nil }
        return smallStorageSummaryText(parts.joined(separator: " • "))
    }

    private static func joinStorageSummary(_ lhs: String, _ rhs: String?) -> String {
        guard let rhs = trimmedStorageString(rhs) else { return lhs }
        return "\(lhs) • \(rhs)"
    }

    private static func smallStorageSummaryText(_ text: String?) -> String? {
        guard let text = trimmedStorageString(text) else { return nil }
        if text.count <= 240 { return text }
        let prefix = text.prefix(237).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix + "…"
    }

    private static func trimmedStorageString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func normalizedToolName(_ raw: String?) -> String? {
        AgentTranscriptToolVisibilityPolicy.normalizedVisibleToolName(raw)
    }

    private static func derivedStatusWord(
        normalizedToolName: String?,
        rawResultJSON: String?,
        rawObject: [String: Any]?,
        executionStatus: AgentTranscriptToolStatus?,
        toolIsError: Bool?,
        context: AgentToolResultProcessingContext?
    ) -> String {
        if normalizedToolName == "bash" {
            let metadata = BashToolResultParser.parseMetadata(raw: rawResultJSON, context: context)
            if let statusWord = AgentTranscriptToolStatusSemantics.normalizedBashStatusWord(
                metadata: metadata,
                rawObject: rawObject
            ) {
                return statusWord
            }
            if let bashTextStatus = bashTextStatus(from: rawResultJSON, context: context) {
                return bashTextStatus
            }
        }
        if let rawStatus = AgentTranscriptToolStatusSemantics.normalizedStatusWord(
            stringValue(rawObject, keys: ["status", "result", "outcome", "state", "subtype"])
        ) {
            return rawStatus
        }
        if let executionStatus, executionStatus != .unknown {
            return AgentTranscriptToolStatusSemantics.persistedStatusWord(from: executionStatus)
        }
        if let toolIsError {
            return toolIsError ? "failed" : "success"
        }
        return "unknown"
    }

    private static func persistedToolIsError(
        normalizedToolName: String?,
        status: AgentTranscriptToolStatus,
        original: Bool?
    ) -> Bool? {
        if normalizedToolName == "bash" {
            return status == .running ? false : nil
        }
        if let original {
            return original
        }
        switch status {
        case .failed, .cancelled:
            return true
        case .success:
            return false
        default:
            return nil
        }
    }

    private static func sanitizedSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?,
        rawObject: [String: Any]?,
        argsJSON: String?,
        rawResultText: String? = nil,
        toolIsError: Bool? = nil,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        let allowExistingRenderSummary = boolValue(rawObject, keys: ["summary_only", "summaryOnly"]) == true
        if let renderSummary = AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            rawObject: rawObject,
            argsObject: jsonObject(from: argsJSON, context: context),
            allowExistingSummaryOnly: allowExistingRenderSummary
        ) {
            return minimalResultJSON(
                statusWord: statusWord,
                normalizedToolName: normalizedToolName,
                processID: processID,
                exitCode: exitCode,
                summaryText: renderSummary.inlineSummaryText,
                renderSummary: renderSummary
            )
        }
        if normalizedToolName == "context_builder",
           let rawOutput = rawObject?["rawOutput"] as? [String: Any]
        {
            return contextBuilderSummaryJSON(
                statusWord: statusWord,
                rawObject: rawOutput
            )
        }
        if let cursorSummaryJSON = cursorACPSummaryJSON(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            rawObject: rawObject,
            toolIsError: toolIsError
        ) {
            return cursorSummaryJSON
        }
        switch normalizedToolName {
        case "apply_edits":
            return applyEditsSummaryJSON(
                statusWord: statusWord,
                rawObject: rawObject
            )
        case "apply_patch":
            return applyPatchSummaryJSON(
                statusWord: statusWord,
                rawObject: rawObject,
                argsJSON: argsJSON,
                context: context
            )
        case "bash":
            return bashSummaryJSON(
                statusWord: statusWord,
                processID: processID,
                exitCode: exitCode
            )
        case "agent_run", "agent_explore":
            return agentRunSummaryJSON(normalizedToolName: normalizedToolName, statusWord: statusWord, rawObject: rawObject)
        case "agent_manage":
            return agentManageSummaryJSON(statusWord: statusWord, rawObject: rawObject)
        case "ask_oracle", "oracle_send":
            return oracleChatSummaryJSON(
                normalizedToolName: normalizedToolName,
                statusWord: statusWord,
                rawObject: rawObject,
                rawResultText: rawResultText,
                toolIsError: toolIsError,
                argsJSON: argsJSON
            )
        case "context_builder":
            return contextBuilderSummaryJSON(
                statusWord: statusWord,
                rawObject: rawObject
            )
        default:
            return genericSummaryJSON(
                normalizedToolName: normalizedToolName,
                statusWord: statusWord,
                processID: processID,
                exitCode: exitCode
            )
        }
    }

    private static func genericSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?
    ) -> String? {
        jsonString(from: genericSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode
        ))
    }

    private static func genericSummaryObject(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "status": statusWord,
            "summary_only": true
        ]
        if normalizedToolName == "bash" {
            object["type"] = "commandExecution"
        }
        if let processID, !processID.isEmpty {
            object["processId"] = processID
        }
        if let exitCode {
            object["exitCode"] = exitCode
        }
        return object
    }

    private static func bashSummaryJSON(
        statusWord: String,
        processID: String?,
        exitCode: Int?
    ) -> String? {
        jsonString(from: genericSummaryObject(
            normalizedToolName: "bash",
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode
        ))
    }

    private static func applyEditsSummaryJSON(
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: "apply_edits",
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        if let editsRequested = intValue(rawObject, keys: ["edits_requested"]) {
            object["edits_requested"] = editsRequested
        }
        if let editsApplied = intValue(rawObject, keys: ["edits_applied"]) {
            object["edits_applied"] = editsApplied
        }
        if let totalLinesChanged = intValue(rawObject, keys: ["total_lines_changed"]) {
            object["total_lines_changed"] = totalLinesChanged
        }
        if let fileCreated = boolValue(rawObject, keys: ["file_created"]) {
            object["file_created"] = fileCreated
        }
        if let fileOverwritten = boolValue(rawObject, keys: ["file_overwritten"]) {
            object["file_overwritten"] = fileOverwritten
        }
        if let reviewStatus = stringValue(rawObject, keys: ["review_status"]),
           !reviewStatus.isEmpty
        {
            object["review_status"] = reviewStatus
        }
        if let requiresUserApproval = boolValue(rawObject, keys: ["requires_user_approval"]) {
            object["requires_user_approval"] = requiresUserApproval
        }
        if let note = smallStringValue(rawObject, keys: ["note"]) {
            object["note"] = note
        }
        if let rejectionReason = smallStringValue(rawObject, keys: ["rejection_reason"]) {
            object["rejection_reason"] = rejectionReason
        }
        return jsonString(from: object)
    }

    private static func applyPatchSummaryJSON(
        statusWord: String,
        rawObject: [String: Any]?,
        argsJSON: String?,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: "apply_patch",
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        let changes = summarizedPatchChanges(from: rawObject)
        object["changes"] = changes
        if let changeCount = intValue(rawObject, keys: ["change_count"]) {
            object["change_count"] = max(changeCount, changes.count)
        } else if let argCount = intValue(jsonObject(from: argsJSON, context: context), keys: ["change_count"]) {
            object["change_count"] = max(argCount, changes.count)
        } else {
            object["change_count"] = changes.count
        }
        return jsonString(from: object)
    }

    private static func summarizedPatchChanges(from rawObject: [String: Any]?) -> [[String: Any]] {
        guard let rawChanges = rawObject?["changes"] as? [[String: Any]] else { return [] }
        return rawChanges.compactMap { change in
            guard let path = stringValue(change, keys: ["path"]),
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            var summarized: [String: Any] = [
                "path": path,
                "kind": stringValue(change, keys: ["kind"]) ?? "update",
                "diff": ""
            ]
            if let movePath = stringValue(change, keys: ["move_path", "movePath"]),
               !movePath.isEmpty
            {
                summarized["move_path"] = movePath
            }
            return summarized
        }
    }

    private static func cursorACPSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?,
        rawObject: [String: Any]?,
        toolIsError: Bool? = nil
    ) -> String? {
        guard let rawObject,
              stringValue(rawObject, keys: ["acp_status"]) != nil
        else { return nil }

        let isEdit = normalizedToolName == "edit"
        var object = cursorACPBaseSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode,
            rawObject: rawObject
        )
        // A failed Cursor Oracle call keeps the same bounded, redacted diagnostics as other
        // providers (the shared projection unwraps `rawOutput`), never raw-output text. A failed
        // ACP call whose wrapped Oracle result was unfinished or cancelled keeps that outcome.
        if normalizedToolName == "ask_oracle" || normalizedToolName == "oracle_send" {
            switch OracleToolResultInspection.classify(object: rawObject, toolIsError: toolIsError, statusWord: statusWord) {
            case let .failed(failure):
                let rawInputMode = (rawObject["rawInput"] as? [String: Any])?["mode"] as? String
                return OracleToolResultInspection.boundedFailureSummaryJSON(
                    base: object,
                    failure: failure,
                    argumentMode: OracleToolResultInspection.recognizedMode(rawInputMode)
                        ?? OracleToolResultInspection.recognizedMode(rawObject["mode"] as? String),
                    statusWord: statusWord,
                    normalizedToolName: normalizedToolName,
                    maxBytes: maxPersistedToolSummaryBytes
                )
            case let .invocationFailureOnly(outcome):
                object[OracleToolResultInspection.Key.oracleOutcome] = outcome.rawValue
            case .notFailed:
                break
            }
        }
        if let content = cursorACPContentSummary(
            from: rawObject,
            isEdit: isEdit,
            diffLimit: cursorACPPersistedDiffBytesLimit
        ), !content.isEmpty {
            object["content"] = content
            if isEdit {
                object["change_count"] = content.count
            }
        }
        if let rawOutput = cursorACPRawOutputSummary(from: rawObject["rawOutput"]) {
            object["rawOutput"] = rawOutput
        }
        if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
            return json
        }
        guard isEdit,
              let compactContent = cursorACPContentSummary(
                  from: rawObject,
                  isEdit: true,
                  diffLimit: cursorACPFallbackPersistedDiffBytesLimit
              ), !compactContent.isEmpty
        else { return nil }
        object["content"] = compactContent
        object["change_count"] = compactContent.count
        return jsonString(from: object).flatMap { exceedsPersistedToolSummaryBudget($0) ? nil : $0 }
    }

    private static func cursorACPBaseSummaryObject(
        normalizedToolName: String?,
        statusWord: String,
        processID: String?,
        exitCode: Int?,
        rawObject: [String: Any]
    ) -> [String: Any] {
        var object = genericSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: processID,
            exitCode: exitCode
        )
        if let acpStatus = smallStringValue(rawObject, keys: ["acp_status"]) {
            object["acp_status"] = acpStatus
        }
        if let kind = smallStringValue(rawObject, keys: ["kind"]) {
            object["kind"] = kind
        }
        if let title = smallStringValue(rawObject, keys: ["title"]) {
            object["title"] = title
        }
        if normalizedToolName == "ask_oracle" || normalizedToolName == "oracle_send" {
            if let chatID = smallStringValue(rawObject, keys: ["chat_id", "chatID"]) {
                object["chat_id"] = chatID
            }
            if let modelPresetName = smallStringValue(rawObject, keys: ["model_preset_name", "modelPresetName"]) {
                object["model_preset_name"] = modelPresetName
            }
            if let modelSelection = smallStringValue(rawObject, keys: ["model_selection", "modelSelection"]) {
                object["model_selection"] = modelSelection
            }
            let modelSource = smallStringValue(rawObject, keys: ["model_source", "modelSource"])
            if let modelSource {
                object["model_source"] = modelSource
            }
            if let modelPresetID = smallStringValue(rawObject, keys: ["model_preset_id", "modelPresetID"]) {
                object["model_preset_id"] = modelPresetID
            }
            if modelSource?.lowercased() != "preset" {
                if let modelName = smallStringValue(rawObject, keys: ["model_name", "modelName"]) {
                    object["model_name"] = modelName
                }
                if let modelID = smallStringValue(rawObject, keys: ["model_id", "modelID"]) {
                    object["model_id"] = modelID
                }
            }
        }
        return object
    }

    private static func cursorACPContentSummary(
        from rawObject: [String: Any],
        isEdit: Bool,
        diffLimit: Int
    ) -> [[String: Any]]? {
        guard let rawContent = rawObject["content"] as? [[String: Any]] else { return nil }
        let summaries: [[String: Any]] = rawContent.compactMap { entry in
            let type = stringValue(entry, keys: ["type"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = stringValue(entry, keys: ["path"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard type?.isEmpty == false || path?.isEmpty == false else { return nil }
            return isEdit
                ? cursorACPEditContentSummary(entry: entry, type: type, path: path, diffLimit: diffLimit)
                : cursorACPNonEditContentSummary(entry: entry, type: type, path: path)
        }
        return summaries.isEmpty ? nil : summaries
    }

    private static func cursorACPEditContentSummary(
        entry: [String: Any],
        type: String?,
        path: String?,
        diffLimit: Int
    ) -> [String: Any]? {
        var summary: [String: Any] = [:]
        if let type, !type.isEmpty { summary["type"] = type }
        if let path, !path.isEmpty { summary["path"] = path }
        if let oldTextTruncated = boolValue(entry, keys: ["oldText_truncated", "old_text_truncated", "oldTextTruncated"]) {
            summary["oldText_truncated"] = oldTextTruncated
        }
        if let newTextTruncated = boolValue(entry, keys: ["newText_truncated", "new_text_truncated", "newTextTruncated"]) {
            summary["newText_truncated"] = newTextTruncated
        }
        if let diffTruncated = boolValue(entry, keys: ["diff_truncated", "diffTruncated"]) {
            summary["diff_truncated"] = diffTruncated
        }
        if let existingDiff = stringValue(entry, keys: ["unified_diff", "card_unified_diff"]),
           let clipped = clippedCursorACPString(existingDiff, limit: diffLimit)
        {
            summary["unified_diff"] = clipped.value
            if clipped.wasTruncated {
                summary["diff_truncated"] = true
            }
            return summary.isEmpty ? nil : summary
        }
        if let path, !path.isEmpty,
           let oldText = stringValue(entry, keys: ["oldText", "old_text"]),
           let newText = stringValue(entry, keys: ["newText", "new_text"])
        {
            copyCursorACPStringMetrics(from: entry, key: "oldText", into: &summary)
            copyCursorACPStringMetrics(from: entry, key: "newText", into: &summary)
            guard shouldGenerateCursorACPDiff(oldText: oldText, newText: newText) else {
                summary["diff_truncated"] = true
                return summary.isEmpty ? nil : summary
            }
            guard let diff = cursorACPUnifiedDiff(path: path, oldText: oldText, newText: newText),
                  let clipped = clippedCursorACPString(diff, limit: diffLimit) else { return summary.isEmpty ? nil : summary }
            summary["unified_diff"] = clipped.value
            if clipped.wasTruncated {
                summary["diff_truncated"] = true
            }
        }
        return summary.isEmpty ? nil : summary
    }

    private static func cursorACPNonEditContentSummary(
        entry: [String: Any],
        type: String?,
        path: String?
    ) -> [String: Any]? {
        var summary: [String: Any] = [:]
        if let type, !type.isEmpty { summary["type"] = type }
        if let path, !path.isEmpty { summary["path"] = path }
        for key in ["text", "content", "output", "oldText", "newText"] {
            copyCursorACPStringMetrics(from: entry, key: key, into: &summary)
        }
        return summary.isEmpty ? nil : summary
    }

    private static func shouldGenerateCursorACPDiff(oldText: String, newText: String) -> Bool {
        let totalBytes = oldText.utf8.count + newText.utf8.count
        guard totalBytes <= cursorACPGeneratedDiffInputBytesLimit else { return false }
        let totalLines = oldText.split(separator: "\n", omittingEmptySubsequences: false).count
            + newText.split(separator: "\n", omittingEmptySubsequences: false).count
        return totalLines <= cursorACPGeneratedDiffInputLineLimit
    }

    private static func cursorACPUnifiedDiff(path: String, oldText: String, newText: String) -> String? {
        let oldLines = String.splitContentPreservingLineEndings(oldText).0
        let newLines = String.splitContentPreservingLineEndings(newText).0
        let chunks = UnifiedDiffGenerator.diffChunks(
            oldLines: oldLines,
            newLines: newLines,
            context: 2
        )
        let diff = UnifiedDiffGenerator.build(filePath: path, chunks: chunks, context: 2)
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : diff
    }

    private static func cursorACPRawOutputSummary(from rawOutput: Any?) -> [String: Any]? {
        guard let rawOutput = rawOutput as? [String: Any], !rawOutput.isEmpty else { return nil }
        var summary: [String: Any] = [:]
        for key in ["success", "truncated", "totalFiles", "exitCode", "code", "stdoutSanitized"] {
            if let value = rawOutput[key], value is Bool || value is NSNumber || value is Int || value is Double {
                summary[key] = value
            }
        }
        for key in ["stdout", "stderr", "content", "output"] {
            copyCursorACPStringMetrics(from: rawOutput, key: key, into: &summary)
            copyExistingCursorACPStringMetrics(from: rawOutput, key: key, into: &summary)
        }
        for key in ["error", "errorMessage", "message"] {
            copyClippedCursorACPString(from: rawOutput, key: key, into: &summary)
        }
        return summary.isEmpty ? nil : summary
    }

    private static func copyCursorACPStringMetrics(
        from object: [String: Any],
        key: String,
        into summary: inout [String: Any]
    ) {
        guard let raw = stringValue(object, keys: [key]),
              !raw.isEmpty else { return }
        summary["\(key)_bytes"] = raw.utf8.count
        summary["\(key)_line_count"] = raw.isEmpty ? 0 : raw.split(separator: "\n", omittingEmptySubsequences: false).count
        if boolValue(object, keys: ["\(key)_truncated", "\(key)Truncated"]) == true {
            summary["\(key)_truncated"] = true
        }
    }

    private static func copyExistingCursorACPStringMetrics(
        from object: [String: Any],
        key: String,
        into summary: inout [String: Any]
    ) {
        if let bytes = intValue(object, keys: ["\(key)_bytes", "\(key)Bytes"]) {
            summary["\(key)_bytes"] = bytes
        }
        if let lineCount = intValue(object, keys: ["\(key)_line_count", "\(key)LineCount"]) {
            summary["\(key)_line_count"] = lineCount
        }
        if boolValue(object, keys: ["\(key)_truncated", "\(key)Truncated"]) == true {
            summary["\(key)_truncated"] = true
        }
    }

    private static func copyClippedCursorACPString(
        from object: [String: Any],
        key: String,
        into summary: inout [String: Any]
    ) {
        guard let raw = stringValue(object, keys: [key]),
              let clipped = clippedCursorACPString(raw) else { return }
        summary[key] = clipped.value
        if clipped.wasTruncated {
            summary["\(key)_truncated"] = true
        }
    }

    private static func clippedCursorACPString(_ raw: String, limit: Int = 600) -> (value: String, wasTruncated: Bool)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > limit else { return (trimmed, false) }
        let prefix = trimmed.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : (prefix + "…", true)
    }

    private static func agentRunSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        if let rawObject {
            if let reason = smallStringValue(rawObject, keys: ["reason"]) {
                object["reason"] = reason
            }
            if let note = smallStringValue(rawObject, keys: ["note"]) {
                object["note"] = note
            }
            if let op = smallStringValue(rawObject, keys: ["op"]) {
                object["op"] = op
            }
            if let statusText = smallStringValue(rawObject, keys: ["status_text"]) {
                object["status_text"] = statusText
            }
            if let assistantText = smallStringValue(rawObject, keys: ["assistant_text"]) {
                object["assistant_text"] = assistantText
            }
            if let transcriptItemCount = intValue(rawObject, keys: ["transcript_item_count"]) {
                object["transcript_item_count"] = transcriptItemCount
            }
            if let workflowID = smallStringValue(rawObject, keys: ["workflow_id"]) {
                object["workflow_id"] = workflowID
            }
            if let workflowName = smallStringValue(rawObject, keys: ["workflow_name"]) {
                object["workflow_name"] = workflowName
            }
            if let waitPolicy = AgentMCPWaitPolicy.canonicalMetadata(from: rawObject) {
                object[AgentMCPWaitPolicy.waitPolicyKey] = waitPolicy.jsonObject
            }
            if let session = rawObject["session"] as? [String: Any] {
                var sessionObject: [String: Any] = [:]
                if let id = stringValue(session, keys: ["id"]), !id.isEmpty {
                    sessionObject["id"] = id
                }
                if let name = smallStringValue(session, keys: ["name"]) {
                    sessionObject["name"] = name
                }
                if !sessionObject.isEmpty {
                    object["session"] = sessionObject
                }
            }
            if let sessionID = stringValue(rawObject, keys: ["session_id"])
                ?? stringValue(rawObject["session"] as? [String: Any], keys: ["id"]),
                !sessionID.isEmpty
            {
                object["session_id"] = sessionID
            }
            if let agent = rawObject["agent"] as? [String: Any] {
                var agentObject: [String: Any] = [:]
                if let id = stringValue(agent, keys: ["id"]), !id.isEmpty {
                    agentObject["id"] = id
                }
                if let name = smallStringValue(agent, keys: ["name"]) {
                    agentObject["name"] = name
                }
                if let model = smallStringValue(agent, keys: ["model"]) {
                    agentObject["model"] = model
                }
                if let reasoningEffort = smallStringValue(agent, keys: ["reasoning_effort"]) {
                    agentObject["reasoning_effort"] = reasoningEffort
                }
                if !agentObject.isEmpty {
                    object["agent"] = agentObject
                }
            }
            if let interaction = rawObject["interaction"] as? [String: Any] {
                var interactionObject: [String: Any] = [:]
                if let id = stringValue(interaction, keys: ["id"]), !id.isEmpty {
                    interactionObject["id"] = id
                }
                if let kind = smallStringValue(interaction, keys: ["kind"]) {
                    interactionObject["kind"] = kind
                }
                if let responseType = smallStringValue(interaction, keys: ["response_type"]) {
                    interactionObject["response_type"] = responseType
                }
                if let prompt = smallStringValue(interaction, keys: ["prompt"]) {
                    interactionObject["prompt"] = prompt
                }
                if !interactionObject.isEmpty {
                    object["interaction"] = interactionObject
                }
            }
            if let meta = rawObject["_meta"] as? [String: Any],
               let delivery = smallStringValue(meta, keys: ["delivery"])
            {
                object["_meta"] = ["delivery": delivery]
            }
        }
        return jsonString(from: object)
    }

    private static func agentManageSummaryJSON(
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: "agent_manage",
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        if let rawObject {
            if let name = smallStringValue(rawObject, keys: ["name"]) {
                object["name"] = name
            }
            if let sessionID = stringValue(rawObject, keys: ["session_id"]), !sessionID.isEmpty {
                object["session_id"] = sessionID
            }
            if let returnedTurnCount = intValue(rawObject, keys: ["returned_turn_count"]) {
                object["returned_turn_count"] = returnedTurnCount
            }
            if let totalTurns = intValue(rawObject, keys: ["total_turns"]) {
                object["total_turns"] = totalTurns
            }
            if let agent = rawObject["agent"] as? [String: Any] {
                var agentObject: [String: Any] = [:]
                if let id = stringValue(agent, keys: ["id"]), !id.isEmpty {
                    agentObject["id"] = id
                }
                if let name = smallStringValue(agent, keys: ["name"]) {
                    agentObject["name"] = name
                }
                if let model = smallStringValue(agent, keys: ["model"]) {
                    agentObject["model"] = model
                }
                if !agentObject.isEmpty {
                    object["agent"] = agentObject
                }
            } else if let agent = smallStringValue(rawObject, keys: ["agent"]) {
                object["agent"] = agent
            }
            if let agents = rawObject["agents"] as? [[String: Any]] {
                object["agents"] = agents.prefix(10).map { agent in
                    var summary: [String: Any] = [:]
                    if let name = smallStringValue(agent, keys: ["name", "id"]) { summary["name"] = name }
                    if let available = boolValue(agent, keys: ["available"]) { summary["available"] = available }
                    return summary
                }
            }
            if let sessions = rawObject["sessions"] as? [[String: Any]] {
                object["sessions"] = sessions.prefix(10).map { session in
                    var summary: [String: Any] = [:]
                    if let name = smallStringValue(session, keys: ["name"]) { summary["name"] = name }
                    if let state = smallStringValue(session, keys: ["state"]) { summary["state"] = state }
                    if let agent = session["agent"] as? [String: Any] {
                        var agentSummary: [String: Any] = [:]
                        if let id = smallStringValue(agent, keys: ["id"]) { agentSummary["id"] = id }
                        if let name = smallStringValue(agent, keys: ["name"]) { agentSummary["name"] = name }
                        if !agentSummary.isEmpty { summary["agent"] = agentSummary }
                    } else if let agent = smallStringValue(session, keys: ["agent"]) {
                        summary["agent"] = agent
                    }
                    return summary
                }
            }
            if let deletedCount = intValue(rawObject, keys: ["deleted_count", "deletedCount"])
                ?? (rawObject["deleted_sessions"] as? [Any])?.count
                ?? (rawObject["deletedSessions"] as? [Any])?.count
            {
                object["deleted_count"] = deletedCount
            }
            if let skippedCount = intValue(rawObject, keys: ["skipped_count", "skippedCount"])
                ?? (rawObject["skipped_sessions"] as? [Any])?.count
                ?? (rawObject["skippedSessions"] as? [Any])?.count
            {
                object["skipped_count"] = skippedCount
            }
            if let deletedCount = object["deleted_count"] as? Int,
               let skippedCount = object["skipped_count"] as? Int
            {
                object["summary_text"] = "\(deletedCount) deleted, \(skippedCount) skipped"
            } else if let deletedCount = object["deleted_count"] as? Int {
                object["summary_text"] = "\(deletedCount) deleted"
            } else if let skippedCount = object["skipped_count"] as? Int {
                object["summary_text"] = "\(skippedCount) skipped"
            }
            if let workflows = rawObject["workflows"] as? [[String: Any]] {
                object["workflows"] = workflows.prefix(10).map { workflow in
                    var summary: [String: Any] = [:]
                    if let name = smallStringValue(workflow, keys: ["name", "id"]) { summary["name"] = name }
                    return summary
                }
            }
        }
        return jsonString(from: object)
    }

    private static func agentManageCountSummaryJSON(
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        let deletedCount = intValue(rawObject, keys: ["deleted_count", "deletedCount"])
        let skippedCount = intValue(rawObject, keys: ["skipped_count", "skippedCount"])
        guard deletedCount != nil || skippedCount != nil else { return nil }
        var object = genericSummaryObject(
            normalizedToolName: "agent_manage",
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        if let deletedCount {
            object["deleted_count"] = deletedCount
        }
        if let skippedCount {
            object["skipped_count"] = skippedCount
        }
        if let deletedCount, let skippedCount {
            object["summary_text"] = "\(deletedCount) deleted, \(skippedCount) skipped"
        } else if let deletedCount {
            object["summary_text"] = "\(deletedCount) deleted"
        } else if let skippedCount {
            object["summary_text"] = "\(skippedCount) skipped"
        }
        return jsonString(from: object)
    }

    private static func contextBuilderSummaryJSON(
        statusWord: String,
        rawObject: [String: Any]?
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: "context_builder",
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        guard let rawObject else { return jsonString(from: object) }

        if let contextID = smallStringValue(rawObject, keys: ["context_id", "tab_id", "tabID"]) {
            object["context_id"] = contextID
        }
        let responseType = smallStringValue(rawObject, keys: ["response_type", "responseType"])
        if let responseType {
            object["response_type"] = responseType
        }

        if let branch = ContextBuilderFollowUpBranch.select(responseType: responseType),
           let reply = boundedContextBuilderReply(rawObject[branch.rawValue] as? [String: Any])
        {
            object[branch.rawValue] = reply
        }

        guard let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) else {
            return minimalResultJSON(statusWord: statusWord, normalizedToolName: "context_builder")
        }
        return json
    }

    private static func boundedContextBuilderReply(_ rawReply: [String: Any]?) -> [String: Any]? {
        guard let rawReply,
              let chatID = smallStringValue(rawReply, keys: ["chat_id", "chatID"])
        else { return nil }
        var reply: [String: Any] = ["chat_id": chatID]
        if let mode = smallStringValue(rawReply, keys: ["mode"]) {
            reply["mode"] = mode
        }
        return reply
    }

    /// Oracle summaries keep identity and outcome metadata. A failed result additionally keeps
    /// its redacted, bounded diagnostics from the shared `OracleToolResultInspection`
    /// projection (plan Patch B), so a reloaded card can explain itself; successful, pending,
    /// and cancelled output is byte-identical to the summary without that projection.
    private static func oracleChatSummaryJSON(
        normalizedToolName: String?,
        statusWord: String,
        rawObject: [String: Any]?,
        rawResultText: String? = nil,
        toolIsError: Bool? = nil,
        argsJSON: String? = nil
    ) -> String? {
        var object = genericSummaryObject(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            processID: nil,
            exitCode: nil
        )
        let classification = OracleToolResultInspection.classify(
            resultJSON: rawResultText,
            text: nil,
            toolIsError: toolIsError,
            statusWord: statusWord
        )
        let failure = classification.failure
        // The invocation `status` stays as it was; the Oracle's own outcome sits beside it.
        var oracleOutcome: String?
        if case let .invocationFailureOnly(outcome) = classification {
            oracleOutcome = outcome.rawValue
            object[OracleToolResultInspection.Key.oracleOutcome] = outcome.rawValue
        }
        func failureSummaryJSON(_ failure: OracleToolResultInspection.Failure) -> String {
            OracleToolResultInspection.boundedFailureSummaryJSON(
                base: object,
                failure: failure,
                argumentMode: OracleToolResultInspection.recognizedMode(fromArgumentsJSON: argsJSON),
                statusWord: statusWord,
                normalizedToolName: normalizedToolName,
                maxBytes: maxPersistedToolSummaryBytes
            )
        }
        guard let rawObject else {
            if let failure {
                return failureSummaryJSON(failure)
            }
            return jsonString(from: object)
        }
        if let chatID = smallStringValue(rawObject, keys: ["chat_id", "chatID"]) {
            object["chat_id"] = chatID
        }
        if let mode = smallStringValue(rawObject, keys: ["mode"]) {
            object["mode"] = mode
        }
        if let modelPresetName = smallStringValue(rawObject, keys: ["model_preset_name", "modelPresetName"]) {
            object["model_preset_name"] = modelPresetName
        }
        if let modelSelection = smallStringValue(rawObject, keys: ["model_selection", "modelSelection"]) {
            object["model_selection"] = modelSelection
        }
        let modelSource = smallStringValue(rawObject, keys: ["model_source", "modelSource"])
        if let modelSource {
            object["model_source"] = modelSource
        }
        if let modelPresetID = smallStringValue(rawObject, keys: ["model_preset_id", "modelPresetID"]) {
            object["model_preset_id"] = modelPresetID
        }
        if modelSource?.lowercased() != "preset" {
            if let modelName = smallStringValue(rawObject, keys: ["model_name", "modelName"]) {
                object["model_name"] = modelName
            }
            if let modelID = smallStringValue(rawObject, keys: ["model_id", "modelID"]) {
                object["model_id"] = modelID
            }
        }
        let diffCount = intValue(rawObject, keys: ["diff_count", "diffCount"])
            ?? (rawObject["diffs"] as? [Any])?.count
            ?? (rawObject["patches"] as? [Any])?.count
        if let diffCount {
            object["diff_count"] = diffCount
        }
        if let response = stringValue(rawObject, keys: ["response"]),
           !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            object["has_response"] = true
        } else if let hasResponse = boolValue(rawObject, keys: ["has_response", "hasResponse"]) {
            object["has_response"] = hasResponse
        }
        let rawErrors = rawObject["errors"] as? [Any] ?? []
        if !rawErrors.isEmpty {
            object["error_count"] = rawErrors.count
        } else if let errorCount = intValue(rawObject, keys: ["error_count", "errorCount"]) {
            object["error_count"] = errorCount
        }
        if let summaryText = oracleChatSummaryText(from: object) {
            object["summary_text"] = summaryText
        }
        if let failure {
            return failureSummaryJSON(failure)
        }
        if let json = jsonString(from: object), !exceedsPersistedToolSummaryBudget(json) {
            return json
        }
        if let oracleOutcome {
            for summaryText in [object["summary_text"] as? String, nil] {
                var minimal = minimalResultObject(
                    statusWord: statusWord,
                    normalizedToolName: normalizedToolName,
                    processID: nil,
                    exitCode: nil,
                    summaryText: summaryText,
                    renderSummary: nil
                )
                minimal[OracleToolResultInspection.Key.oracleOutcome] = oracleOutcome
                if let json = jsonString(from: minimal), !exceedsPersistedToolSummaryBudget(json) {
                    return json
                }
            }
        }
        return minimalResultJSON(
            statusWord: statusWord,
            normalizedToolName: normalizedToolName,
            summaryText: object["summary_text"] as? String
        )
    }

    package static func uiFacingOracleIdentityJSON(
        toolName: String?,
        rawResultJSON: String
    ) -> String? {
        let normalizedToolName = normalizedToolName(toolName)
        guard normalizedToolName == "ask_oracle" || normalizedToolName == "oracle_send",
              let rawObject = jsonObject(from: rawResultJSON, context: nil)
        else {
            return nil
        }
        let rawOutput = rawObject["rawOutput"] as? [String: Any]
        let identityObject: [String: Any] = {
            if smallStringValue(rawObject, keys: ["model_source", "modelSource"]) != nil {
                return rawObject
            }
            return rawOutput ?? rawObject
        }()
        guard smallStringValue(identityObject, keys: ["model_source", "modelSource"])?.lowercased() == "preset"
        else {
            return nil
        }

        let modelID = smallStringValue(identityObject, keys: ["ui_model_id", "model_id", "modelID"])
        let modelName = smallStringValue(identityObject, keys: ["ui_model_name", "model_name", "modelName"])
        guard modelID != nil || modelName != nil else { return nil }

        var object: [String: Any] = ["model_source": "preset"]
        if let chatID = smallStringValue(identityObject, keys: ["chat_id", "chatID"]) {
            object["chat_id"] = chatID
        }
        if let mode = smallStringValue(identityObject, keys: ["mode"]) {
            object["mode"] = mode
        }
        if let modelSelection = smallStringValue(identityObject, keys: ["model_selection", "modelSelection"]) {
            object["model_selection"] = modelSelection
        }
        if let modelPresetID = smallStringValue(identityObject, keys: ["model_preset_id", "modelPresetID"]) {
            object["model_preset_id"] = modelPresetID
        }
        if let modelPresetName = smallStringValue(identityObject, keys: ["model_preset_name", "modelPresetName"]) {
            object["model_preset_name"] = modelPresetName
        }
        if let modelID {
            object["ui_model_id"] = modelID
        }
        if let modelName {
            object["ui_model_name"] = modelName
        }
        guard let json = jsonString(from: object),
              !exceedsPersistedToolSummaryBudget(json)
        else {
            return nil
        }
        return json
    }

    package static func uiFacingOracleIdentityJSONByChatID(
        toolName: String?,
        rawResultJSON: String
    ) -> [String: String] {
        let normalizedToolName = normalizedToolName(toolName)
        guard normalizedToolName == "ask_oracle" || normalizedToolName == "oracle_send",
              let root = jsonObject(from: rawResultJSON, context: nil)
        else {
            return [:]
        }

        var sidecars: [String: String] = [:]
        func visit(_ value: Any) {
            if let object = value as? [String: Any] {
                if let raw = jsonString(from: object),
                   let sidecar = uiFacingOracleIdentityJSON(
                       toolName: normalizedToolName,
                       rawResultJSON: raw
                   ),
                   let sidecarObject = jsonObject(from: sidecar, context: nil),
                   let chatID = smallStringValue(sidecarObject, keys: ["chat_id", "chatID"])
                {
                    sidecars[chatID] = sidecar
                }
                object.values.forEach(visit)
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }
        visit(root)
        return sidecars
    }

    static func mergingOracleUIIdentitySidecars(
        into rawResultJSON: String,
        sidecarsByChatID: [String: String]
    ) -> String {
        guard !sidecarsByChatID.isEmpty,
              let root = jsonObject(from: rawResultJSON, context: nil)
        else {
            return rawResultJSON
        }

        func merge(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                if let chatID = smallStringValue(object, keys: ["chat_id", "chatID"]),
                   let sidecar = sidecarsByChatID[chatID],
                   let identity = jsonObject(from: sidecar, context: nil)
                {
                    if let modelID = smallStringValue(identity, keys: ["ui_model_id"]) {
                        object["ui_model_id"] = modelID
                    }
                    if let modelName = smallStringValue(identity, keys: ["ui_model_name"]) {
                        object["ui_model_name"] = modelName
                    }
                }
                for (key, child) in object {
                    object[key] = merge(child)
                }
                return object
            }
            if let array = value as? [Any] {
                return array.map(merge)
            }
            return value
        }

        guard let merged = merge(root) as? [String: Any],
              let json = jsonString(from: merged)
        else {
            return rawResultJSON
        }
        return json
    }

    private static func oracleChatSummaryText(from object: [String: Any]) -> String? {
        var parts: [String] = []
        if let mode = stringValue(object, keys: ["mode"]), !mode.isEmpty {
            parts.append(mode)
        }
        if let model = stringValue(object, keys: ["model_preset_name", "model_name"]), !model.isEmpty {
            parts.append(model)
        }
        let diffCount = intValue(object, keys: ["diff_count", "diffCount"])
        if let chatID = stringValue(object, keys: ["chat_id", "chatID"]),
           !chatID.isEmpty,
           parts.isEmpty || (diffCount ?? 0) == 0
        {
            parts.append(chatID)
        }
        if let diffCount, diffCount > 0 {
            parts.append("\(diffCount) \(diffCount == 1 ? "diff" : "diffs")")
        }
        if parts.isEmpty,
           let errorCount = intValue(object, keys: ["error_count", "errorCount"]),
           errorCount > 0
        {
            parts.append("\(errorCount) \(errorCount == 1 ? "error" : "errors")")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " • ")
    }

    private static func normalizedAgentRunStatusWord(_ raw: String?) -> String? {
        guard let normalized = AgentTranscriptToolStatusSemantics.normalizedStatusWord(raw) else {
            return nil
        }
        switch normalized {
        case "success":
            return "completed"
        case "running", "waiting_for_input", "completed", "failed", "cancelled", "expired":
            return normalized
        default:
            return nil
        }
    }

    private static func transcriptStatusForAgentRunStatusWord(_ statusWord: String) -> AgentTranscriptToolStatus {
        switch statusWord {
        case "running":
            .running
        case "waiting_for_input":
            .warning
        case "completed":
            .success
        case "failed":
            .failed
        case "cancelled":
            .cancelled
        case "expired":
            .warning
        default:
            .unknown
        }
    }

    private static func isTerminalAgentRunStatusWord(_ statusWord: String) -> Bool {
        switch statusWord {
        case "completed", "failed", "cancelled", "expired":
            true
        default:
            false
        }
    }

    private static func smallStringValue(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let value = stringValue(object, keys: keys)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.count <= 240
        else {
            return nil
        }
        return value
    }

    private static let bashProcessIDRegex = try! NSRegularExpression(
        pattern: #"process\s+running\s+with\s+session\s+id\s+([^\s]+)"#,
        options: [.caseInsensitive]
    )
    private static let bashExitCodeRegex = try! NSRegularExpression(
        pattern: #"process\s+completed\s+with\s+exit\s+code\s+(-?[0-9]+)"#,
        options: [.caseInsensitive]
    )

    private static func bashTextProcessID(from raw: String?, context: AgentToolResultProcessingContext? = nil) -> String? {
        captureFirstGroup(
            in: raw,
            regex: bashProcessIDRegex,
            context: context
        )
    }

    private static func bashTextExitCode(from raw: String?, context: AgentToolResultProcessingContext? = nil) -> Int? {
        guard let captured = captureFirstGroup(
            in: raw,
            regex: bashExitCodeRegex,
            context: context
        ) else {
            return nil
        }
        return Int(captured)
    }

    private static func bashTextStatus(from raw: String?, context: AgentToolResultProcessingContext? = nil) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let lowered = raw.lowercased()
        if lowered.contains("process running with session id")
            || lowered.contains("\"status\":\"running\"")
            || lowered.contains("\"status\": \"running\"")
        {
            return "running"
        }
        if let exitCode = bashTextExitCode(from: raw, context: context) {
            return exitCode == 0 ? "success" : "failed"
        }
        if lowered.contains("stdin is closed for this session") {
            return "failed"
        }
        return nil
    }

    private static func captureFirstGroup(
        in text: String?,
        regex: NSRegularExpression,
        context: AgentToolResultProcessingContext?
    ) -> String? {
        context?.recordRegexCapture()
        guard let text, !text.isEmpty else {
            return nil
        }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }
        let groupRange = match.range(at: 1)
        guard groupRange.location != NSNotFound,
              let swiftRange = Range(groupRange, in: text)
        else {
            return nil
        }
        let captured = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return captured.isEmpty ? nil : captured
    }

    private static func jsonObject(from raw: String?, context: AgentToolResultProcessingContext? = nil) -> [String: Any]? {
        if let context {
            return context.jsonObject(from: raw)
        }
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private static func jsonString(from object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private static func stringValue(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? String {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    private static func boolValue(_ object: [String: Any]?, keys: [String]) -> Bool? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? Bool {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.boolValue
            }
        }
        return nil
    }

    private static func intValue(_ object: [String: Any]?, keys: [String]) -> Int? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? Int {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.intValue
            }
            if let value = object[key] as? String,
               let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return intValue
            }
        }
        return nil
    }
}
