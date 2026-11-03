import Foundation
import RepoPromptWorkspace

/// Namespace for MCP Tool result DTOs.
/// Using a namespace avoids name collisions with existing private structs
/// in MCPServerViewModel during the migration phase.
package enum ToolResultDTOs {
    // MARK: - Worktree Scope

    package struct WorktreeScopeDTO: Codable, Equatable {
        package struct RootMappingDTO: Codable, Equatable {
            package let logicalRootName: String
            let logicalRootPath: String
            let effectiveRootName: String
            let effectiveRootPath: String
            package let worktreeID: String
            package let worktreeName: String?
            package let branch: String?
            package let label: String?

            private enum CodingKeys: String, CodingKey {
                case logicalRootName = "logical_root_name"
                case logicalRootPath = "logical_root_path"
                case effectiveRootName = "effective_root_name"
                case effectiveRootPath = "effective_root_path"
                case worktreeID = "worktree_id"
                case worktreeName = "worktree_name"
                case branch
                case label
            }
        }

        let kind: String
        let displayIdentity: String
        let effectiveIdentity: String
        package let rootMappings: [RootMappingDTO]

        package static func sessionBound(from projection: WorkspaceRootBindingProjection?) -> WorktreeScopeDTO? {
            guard let projection, !projection.isEmpty else { return nil }
            let rootLabels = WorkspaceLogicalRootIdentity.labels(
                for: projection.boundRootsForMetadata.map { boundRoot in
                    WorkspaceLogicalRootIdentity.RootDescriptor(
                        physicalRootID: boundRoot.physicalRoot.id,
                        rootEpoch: WorkspaceCodemapRootEpoch(
                            rootID: boundRoot.logicalRoot.id,
                            rootLifetimeID: boundRoot.physicalRoot.id
                        ),
                        preferredName: boundRoot.logicalRoot.name
                    )
                }
            )
            let mappings = projection.boundRootsForMetadata.compactMap { boundRoot -> RootMappingDTO? in
                let logicalPath = boundRoot.logicalRoot.standardizedFullPath
                let effectivePath = boundRoot.physicalRoot.standardizedFullPath
                guard logicalPath != effectivePath else { return nil }
                let logicalRootLabel = rootLabels[boundRoot.physicalRoot.id] ?? boundRoot.logicalRoot.name
                return RootMappingDTO(
                    logicalRootName: logicalRootLabel,
                    logicalRootPath: logicalRootLabel,
                    effectiveRootName: effectiveRootName(for: boundRoot),
                    effectiveRootPath: "session-bound",
                    worktreeID: boundRoot.binding.worktreeID,
                    worktreeName: boundRoot.binding.worktreeName,
                    branch: boundRoot.binding.branch,
                    label: boundRoot.binding.visualLabel
                )
            }
            guard !mappings.isEmpty else { return nil }
            return WorktreeScopeDTO(
                kind: "session_bound_worktree",
                displayIdentity: "logical_canonical_root",
                effectiveIdentity: "bound_worktree_root",
                rootMappings: mappings
            )
        }

        private static func effectiveRootName(for boundRoot: WorkspaceRootBindingProjection.BoundRoot) -> String {
            if let worktreeName = nonEmpty(boundRoot.binding.worktreeName) {
                return worktreeName
            }
            let basename = URL(fileURLWithPath: boundRoot.binding.worktreeRootPath).lastPathComponent
            if !basename.isEmpty {
                return basename
            }
            return boundRoot.physicalRoot.name
        }

        private static func nonEmpty(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        private enum CodingKeys: String, CodingKey {
            case kind
            case displayIdentity = "display_identity"
            case effectiveIdentity = "effective_identity"
            case rootMappings = "root_mappings"
        }
    }

    // MARK: - Search

    package struct PerFileCount: Codable, Equatable {
        package let path: String
        package let count: Int

        package init(
            path: String,
            count: Int
        ) {
            self.path = path
            self.count = count
        }
    }

    package struct SearchResultDTO: Codable, Equatable {
        package struct ContentMatchGroup: Codable, Equatable {
            package struct ContextLine: Codable, Equatable, Hashable {
                package let lineNumber: Int
                package let lineText: String

                package init(
                    lineNumber: Int,
                    lineText: String
                ) {
                    self.lineNumber = lineNumber
                    self.lineText = lineText
                }

                private enum CodingKeys: String, CodingKey {
                    case lineNumber = "line_number"
                    case lineText = "line_text"
                }
            }

            package struct Line: Codable, Equatable {
                package let lineNumber: Int
                package let lineText: String
                package let contextBefore: [ContextLine]?
                package let contextAfter: [ContextLine]?

                package init(
                    lineNumber: Int,
                    lineText: String,
                    contextBefore: [ContextLine]?,
                    contextAfter: [ContextLine]?
                ) {
                    self.lineNumber = lineNumber
                    self.lineText = lineText
                    self.contextBefore = contextBefore
                    self.contextAfter = contextAfter
                }

                private enum CodingKeys: String, CodingKey {
                    case lineNumber = "line_number"
                    case lineText = "line_text"
                    case contextBefore = "context_before"
                    case contextAfter = "context_after"
                }
            }

            package let path: String
            package let lines: [Line]

            package init(
                path: String,
                lines: [Line]
            ) {
                self.path = path
                self.lines = lines
            }

            private enum CodingKeys: String, CodingKey {
                case path
                case lines
            }
        }

        package let totalMatches: Int
        package let totalFiles: Int
        package let matchedFiles: Int?
        package let searchedFiles: Int?
        package let contentMatches: Int
        package let pathMatches: Int
        package let limitHit: Bool
        package let perFileCounts: [PerFileCount]
        package let pathMatchLines: [String]
        package let contentMatchGroups: [ContentMatchGroup]

        // NEW (optional, default nil) — indicates size-based trimming
        package let sizeLimitHit: Bool?
        package let omittedTotal: Int?
        package let omittedContentMatches: Int?
        package let omittedPathMatches: Int?
        package let errorMessage: String?
        package let errorCode: String?
        package let retryable: Bool?
        package let retryAfterMilliseconds: Int?
        package let suggestion: String?
        package let warning: String?
        package let perFileTotals: [PerFileCount]?
        package let worktreeScope: WorktreeScopeDTO?

        /// Custom initializer to keep existing call sites source-compatible while allowing optional size-cap fields.
        package init(
            totalMatches: Int,
            totalFiles: Int,
            matchedFiles: Int? = nil,
            searchedFiles: Int? = nil,
            contentMatches: Int,
            pathMatches: Int,
            limitHit: Bool,
            perFileCounts: [PerFileCount],
            pathMatchLines: [String],
            contentMatchGroups: [ContentMatchGroup],
            sizeLimitHit: Bool? = nil,
            omittedTotal: Int? = nil,
            omittedContentMatches: Int? = nil,
            omittedPathMatches: Int? = nil,
            errorMessage: String? = nil,
            errorCode: String? = nil,
            retryable: Bool? = nil,
            retryAfterMilliseconds: Int? = nil,
            suggestion: String? = nil,
            warning: String? = nil,
            perFileTotals: [PerFileCount]? = nil,
            worktreeScope: WorktreeScopeDTO? = nil
        ) {
            self.totalMatches = totalMatches
            self.totalFiles = totalFiles
            self.matchedFiles = matchedFiles
            self.searchedFiles = searchedFiles
            self.contentMatches = contentMatches
            self.pathMatches = pathMatches
            self.limitHit = limitHit
            self.perFileCounts = perFileCounts
            self.pathMatchLines = pathMatchLines
            self.contentMatchGroups = contentMatchGroups
            self.sizeLimitHit = sizeLimitHit
            self.omittedTotal = omittedTotal
            self.omittedContentMatches = omittedContentMatches
            self.omittedPathMatches = omittedPathMatches
            self.errorMessage = errorMessage
            self.errorCode = errorCode
            self.retryable = retryable
            self.retryAfterMilliseconds = retryAfterMilliseconds
            self.suggestion = suggestion
            self.warning = warning
            self.perFileTotals = perFileTotals
            self.worktreeScope = worktreeScope
        }

        private enum CodingKeys: String, CodingKey {
            case totalMatches = "total_matches"
            case totalFiles = "total_files"
            case matchedFiles = "matched_files"
            case searchedFiles = "searched_files"
            case contentMatches = "content_matches"
            case pathMatches = "path_matches"
            case limitHit = "limit_hit"
            case perFileCounts = "per_file_counts"
            case pathMatchLines = "path_match_lines"
            case contentMatchGroups = "content_match_groups"

            // NEW keys
            case sizeLimitHit = "size_limit_hit"
            case omittedTotal = "omitted_total"
            case omittedContentMatches = "omitted_content_matches"
            case omittedPathMatches = "omitted_path_matches"
            case errorMessage = "error"
            case errorCode = "error_code"
            case retryable
            case retryAfterMilliseconds = "retry_after_ms"
            case suggestion
            case warning
            case perFileTotals = "per_file_totals"
            case worktreeScope = "worktree_scope"
        }
    }

    // MARK: - File Tree

    package struct FileTreeDTO: Codable, Equatable {
        package let rootsCount: Int
        package let usesLegend: Bool
        package let tree: String
        package let note: String?
        package let wasTruncated: Bool?
        package let worktreeScope: WorktreeScopeDTO?

        package init(
            rootsCount: Int,
            usesLegend: Bool,
            tree: String,
            note: String? = nil,
            wasTruncated: Bool? = nil,
            worktreeScope: WorktreeScopeDTO? = nil
        ) {
            self.rootsCount = rootsCount
            self.usesLegend = usesLegend
            self.tree = tree
            self.note = note
            self.wasTruncated = wasTruncated
            self.worktreeScope = worktreeScope
        }

        private enum CodingKeys: String, CodingKey {
            case rootsCount = "roots_count"
            case usesLegend = "uses_legend"
            case tree
            case note
            case wasTruncated = "was_truncated"
            case worktreeScope = "worktree_scope"
        }
    }

    // MARK: - Code Structure

    package struct CodeStructureReplyDTO: Codable, Equatable {
        package struct FileDTO: Codable, Equatable {
            package let path: String
            package let role: String
            package let depth: Int
            package let reachedBy: [String]
            package let content: String
            package let tokens: Int

            package init(
                path: String,
                role: String,
                depth: Int,
                reachedBy: [String],
                content: String,
                tokens: Int
            ) {
                self.path = path
                self.role = role
                self.depth = depth
                self.reachedBy = reachedBy
                self.content = content
                self.tokens = tokens
            }

            private enum CodingKeys: String, CodingKey {
                case path, role, depth, content, tokens
                case reachedBy = "reached_by"
            }
        }

        package struct SummaryDTO: Codable, Equatable {
            let requestedSeeds: Int
            let resolvedSeeds: Int
            package let returnedSeeds: Int
            package let returnedRelated: Int
            package let returnedFiles: Int
            package let codemapContentTokens: Int
            package let examinedEdges: Int

            package init(
                requestedSeeds: Int,
                resolvedSeeds: Int,
                returnedSeeds: Int,
                returnedRelated: Int,
                returnedFiles: Int,
                codemapContentTokens: Int,
                examinedEdges: Int
            ) {
                self.requestedSeeds = requestedSeeds
                self.resolvedSeeds = resolvedSeeds
                self.returnedSeeds = returnedSeeds
                self.returnedRelated = returnedRelated
                self.returnedFiles = returnedFiles
                self.codemapContentTokens = codemapContentTokens
                self.examinedEdges = examinedEdges
            }

            private enum CodingKeys: String, CodingKey {
                case requestedSeeds = "requested_seeds"
                case resolvedSeeds = "resolved_seeds"
                case returnedSeeds = "returned_seeds"
                case returnedRelated = "returned_related"
                case returnedFiles = "returned_files"
                case codemapContentTokens = "codemap_content_tokens"
                case examinedEdges = "examined_edges"
            }
        }

        package struct IssueDTO: Codable, Equatable {
            package let code: String
            package let phase: String
            package let path: String?
            package let retryable: Bool
            package let retryAfterMilliseconds: Int?
            package let attempted: Int?
            package let limit: Int?
            package let message: String
            package let detail: String?

            package init(
                code: String,
                phase: String,
                path: String?,
                retryable: Bool,
                retryAfterMilliseconds: Int?,
                attempted: Int?,
                limit: Int?,
                message: String,
                detail: String? = nil
            ) {
                self.code = code
                self.phase = phase
                self.path = path
                self.retryable = retryable
                self.retryAfterMilliseconds = retryAfterMilliseconds
                self.attempted = attempted
                self.limit = limit
                self.message = message
                self.detail = detail
            }

            private enum CodingKeys: String, CodingKey {
                case code, phase, path, retryable, attempted, limit, message, detail
                case retryAfterMilliseconds = "retry_after_ms"
            }
        }

        package struct RetryDTO: Codable, Equatable {
            let retryable: Bool
            let retryAfterMilliseconds: Int?

            package init(
                retryable: Bool,
                retryAfterMilliseconds: Int?
            ) {
                self.retryable = retryable
                self.retryAfterMilliseconds = retryAfterMilliseconds
            }

            private enum CodingKeys: String, CodingKey {
                case retryable
                case retryAfterMilliseconds = "retry_after_ms"
            }
        }

        package let status: String
        package let files: [FileDTO]
        package let summary: SummaryDTO
        package let issues: [IssueDTO]
        let retry: RetryDTO?
        package let worktreeScope: WorktreeScopeDTO?

        package init(
            status: String,
            files: [FileDTO],
            summary: SummaryDTO,
            issues: [IssueDTO],
            retry: RetryDTO?,
            worktreeScope: WorktreeScopeDTO?
        ) {
            self.status = status
            self.files = files
            self.summary = summary
            self.issues = issues
            self.retry = retry
            self.worktreeScope = worktreeScope
        }

        private enum CodingKeys: String, CodingKey {
            case status, files, summary, issues, retry
            case worktreeScope = "worktree_scope"
        }
    }

    package struct SelectedCodeStructureDTO: Codable, Equatable {
        package let fileCount: Int
        package let content: String
        /// Paths (display-form) that are selected but have **no codemap** available
        package let unmappedPaths: [String]?
        /// Paths still awaiting a codemap after repair scheduling
        package let pendingPaths: [String]?
        /// Number of additional files with codemaps omitted due to `max_results` cap
        package let omittedCount: Int?
        /// Total number of codemaps omitted due to all limits
        package let omittedTotal: Int?
        /// Number of codemaps omitted due to the response token budget
        package let tokenBudgetOmittedCount: Int?
        /// Indicates the response token budget prevented more codemaps from being emitted
        package let tokenBudgetHit: Bool?
        let worktreeScope: WorktreeScopeDTO?
        /// Root-scoped terminal automatic-codemap conditions; omitted when no root is affected
        package let automaticCodemapIssues: [AutomaticCodemapIssueDTO]?

        package init(
            fileCount: Int,
            content: String,
            unmappedPaths: [String]? = nil,
            pendingPaths: [String]? = nil,
            omittedCount: Int? = nil,
            omittedTotal: Int? = nil,
            tokenBudgetOmittedCount: Int? = nil,
            tokenBudgetHit: Bool? = nil,
            worktreeScope: WorktreeScopeDTO? = nil,
            automaticCodemapIssues: [AutomaticCodemapIssueDTO]? = nil
        ) {
            self.fileCount = fileCount
            self.content = content
            self.unmappedPaths = unmappedPaths
            self.pendingPaths = pendingPaths
            self.omittedCount = omittedCount
            self.omittedTotal = omittedTotal
            self.tokenBudgetOmittedCount = tokenBudgetOmittedCount
            self.tokenBudgetHit = tokenBudgetHit
            self.worktreeScope = worktreeScope
            self.automaticCodemapIssues = automaticCodemapIssues
        }

        private enum CodingKeys: String, CodingKey {
            case fileCount = "file_count"
            case content
            case unmappedPaths = "unmapped_paths"
            case pendingPaths = "pending_paths"
            case omittedCount = "codemaps_omitted"
            case omittedTotal = "omitted_total"
            case tokenBudgetOmittedCount = "token_budget_omitted"
            case tokenBudgetHit = "token_budget_hit"
            case worktreeScope = "worktree_scope"
            case automaticCodemapIssues = "automatic_codemap_issues"
        }
    }

    /// One root whose automatic codemaps are terminally unavailable for this response.
    package struct AutomaticCodemapIssueDTO: Codable, Equatable {
        package let rootID: String
        package let reason: String
        package let message: String

        package init(rootID: String, reason: String, message: String) {
            self.rootID = rootID
            self.reason = reason
            self.message = message
        }

        private enum CodingKeys: String, CodingKey {
            case rootID = "root_id"
            case reason, message
        }
    }

    // MARK: - Selected Files Content (bulk read)

    // (Removed) SelectedFilesContentDTO — superseded by workspace_context `file_blocks`

    // MARK: - Prompt State (legacy)

    package struct PromptStateReply: Codable, Equatable {
        package let prompt: String
        package let selectedPaths: [String]
        /// Optional line-range slices for selected files.
        /// Only includes paths with actual slices; full-file selections are represented only in `selectedPaths`.
        package let fileSlices: [FileSliceDTO]?

        private enum CodingKeys: String, CodingKey {
            case prompt
            case selectedPaths = "selected_paths"
            case fileSlices = "file_slices"
        }
    }

    // MARK: - Selection (list and mutations)

    package struct LineRangeDTO: Codable, Equatable {
        package let startLine: Int
        package let endLine: Int
        /// Optional description explaining what this slice contains and why it's relevant
        package let description: String?

        init(startLine: Int, endLine: Int, description: String? = nil) {
            self.startLine = startLine
            self.endLine = endLine
            self.description = description
        }

        package init(range: LineRange) {
            self.init(startLine: range.start, endLine: range.end, description: range.description)
        }

        private enum CodingKeys: String, CodingKey {
            case startLine = "start_line"
            case endLine = "end_line"
            case description
        }
    }

    package struct FileSliceDTO: Codable, Equatable {
        package let path: String
        package let ranges: [LineRangeDTO]
        /// Absolute workspace/root path for markdown grouping. `path` remains the requested display path.
        let rootPath: String?
        /// File path relative to `rootPath`, used for markdown tree rendering.
        let pathWithinRoot: String?

        package init(
            path: String,
            ranges: [LineRangeDTO],
            rootPath: String? = nil,
            pathWithinRoot: String? = nil
        ) {
            self.path = path
            self.ranges = ranges
            self.rootPath = rootPath
            self.pathWithinRoot = pathWithinRoot
        }

        private enum CodingKeys: String, CodingKey {
            case path
            case ranges
            case rootPath = "root_path"
            case pathWithinRoot = "path_within_root"
        }
    }

    package struct SelectedFileInfo: Codable, Equatable {
        /// How a file would render under the user's copy preset (when different from auto view)
        package struct CopyPresetProjection: Codable, Equatable {
            package let tokens: Int
            package let renderMode: String // "full" | "slice" | "codemap" | "hidden"
            let ranges: [LineRangeDTO]? // for slice
            let codemapOrigin: String? // if codemap: "selected_mode", etc.

            package init(
                tokens: Int,
                renderMode: String,
                ranges: [LineRangeDTO]?,
                codemapOrigin: String?
            ) {
                self.tokens = tokens
                self.renderMode = renderMode
                self.ranges = ranges
                self.codemapOrigin = codemapOrigin
            }

            private enum CodingKeys: String, CodingKey {
                case tokens
                case renderMode = "render_mode"
                case ranges
                case codemapOrigin = "codemap_origin"
            }
        }

        package let path: String
        package let tokens: Int
        package let renderMode: String
        package let ranges: [LineRangeDTO]?
        package let isAuto: Bool
        /// Why this file is rendered as a codemap: "auto", "manual", or "selected_mode". Nil for non-codemap files.
        package let codemapOrigin: String?
        /// How this file would render under the user's copy preset (only set when it differs from auto view)
        package let copyPreset: CopyPresetProjection?
        /// Absolute workspace/root path for markdown grouping. `path` remains the requested display path.
        package let rootPath: String?
        /// File path relative to `rootPath`, used for markdown tree rendering.
        package let pathWithinRoot: String?

        package init(
            path: String,
            tokens: Int,
            renderMode: String,
            ranges: [LineRangeDTO]?,
            isAuto: Bool,
            codemapOrigin: String?,
            copyPreset: CopyPresetProjection?,
            rootPath: String? = nil,
            pathWithinRoot: String? = nil
        ) {
            self.path = path
            self.tokens = tokens
            self.renderMode = renderMode
            self.ranges = ranges
            self.isAuto = isAuto
            self.codemapOrigin = codemapOrigin
            self.copyPreset = copyPreset
            self.rootPath = rootPath
            self.pathWithinRoot = pathWithinRoot
        }

        private enum CodingKeys: String, CodingKey {
            case path
            case tokens
            case renderMode = "render_mode"
            case ranges
            case isAuto = "is_auto"
            case codemapOrigin = "codemap_origin"
            case copyPreset = "copy_preset"
            case rootPath = "root_path"
            case pathWithinRoot = "path_within_root"
        }
    }

    package struct SelectionSummary: Codable, Equatable {
        package let fullCount: Int
        package let sliceCount: Int
        package let codemapCount: Int
        package let fullTokens: Int
        package let sliceTokens: Int
        package let codemapTokens: Int

        package init(
            fullCount: Int,
            sliceCount: Int,
            codemapCount: Int,
            fullTokens: Int,
            sliceTokens: Int,
            codemapTokens: Int
        ) {
            self.fullCount = fullCount
            self.sliceCount = sliceCount
            self.codemapCount = codemapCount
            self.fullTokens = fullTokens
            self.sliceTokens = sliceTokens
            self.codemapTokens = codemapTokens
        }

        private enum CodingKeys: String, CodingKey {
            case fullCount = "full_count"
            case sliceCount = "slice_count"
            case codemapCount = "codemap_count"
            case fullTokens = "full_tokens"
            case sliceTokens = "slice_tokens"
            case codemapTokens = "codemap_tokens"
        }
    }

    package struct SelectedFilesReply: Codable, Equatable {
        package let files: [SelectedFileInfo]
        package let totalTokens: Int
        package let fileSlices: [FileSliceDTO]?
        package let summary: SelectionSummary?
        /// The active codemap usage mode: "auto", "complete", "selected", or "none"
        var codeMapUsage: String? = nil

        // MARK: - User Preset State Indicators (for virtual contexts)

        /// User's copy preset codemap mode (so builder knows user's actual view)
        package var userCopyCodeMapUsage: String? = nil
        /// User's chat preset codemap mode
        package var userChatCodeMapUsage: String? = nil
        /// Token count under user's copy preset settings
        package var userCopyTokens: Int? = nil
        /// Token count under user's chat preset settings
        package var userChatTokens: Int? = nil
        /// What this reply uses (e.g. "auto" for virtual contexts, nil if live)
        package var normalizedCodeMapUsage: String? = nil
        /// Summary of how selection would render under the effective copy preset (when it differs from auto)
        package var copyPresetProjection: CopyPresetProjectionSummaryDTO? = nil
        /// Content tokens (full + slice) under user's copy preset settings
        package var userCopyContentTokens: Int? = nil
        /// Codemap tokens under user's copy preset settings (0 when codemaps disabled)
        package var userCopyCodemapTokens: Int? = nil

        package init(
            files: [SelectedFileInfo],
            totalTokens: Int,
            fileSlices: [FileSliceDTO]?,
            summary: SelectionSummary?,
            codeMapUsage: String? = nil,
            userCopyCodeMapUsage: String? = nil,
            userChatCodeMapUsage: String? = nil,
            userCopyTokens: Int? = nil,
            userChatTokens: Int? = nil,
            normalizedCodeMapUsage: String? = nil,
            copyPresetProjection: CopyPresetProjectionSummaryDTO? = nil,
            userCopyContentTokens: Int? = nil,
            userCopyCodemapTokens: Int? = nil
        ) {
            self.files = files
            self.totalTokens = totalTokens
            self.fileSlices = fileSlices
            self.summary = summary
            self.codeMapUsage = codeMapUsage
            self.userCopyCodeMapUsage = userCopyCodeMapUsage
            self.userChatCodeMapUsage = userChatCodeMapUsage
            self.userCopyTokens = userCopyTokens
            self.userChatTokens = userChatTokens
            self.normalizedCodeMapUsage = normalizedCodeMapUsage
            self.copyPresetProjection = copyPresetProjection
            self.userCopyContentTokens = userCopyContentTokens
            self.userCopyCodemapTokens = userCopyCodemapTokens
        }

        private enum CodingKeys: String, CodingKey {
            case files
            case totalTokens = "total_tokens"
            case fileSlices = "file_slices"
            case summary
            case codeMapUsage = "code_map_usage"
            case userCopyCodeMapUsage = "user_copy_codemap_usage"
            case userChatCodeMapUsage = "user_chat_codemap_usage"
            case userCopyTokens = "user_copy_tokens"
            case userChatTokens = "user_chat_tokens"
            case normalizedCodeMapUsage = "normalized_codemap_usage"
            case copyPresetProjection = "copy_preset_projection"
            case userCopyContentTokens = "user_copy_content_tokens"
            case userCopyCodemapTokens = "user_copy_codemap_tokens"
        }
    }

    package struct SelectionReply: Codable, Equatable {
        package let files: [SelectedFileInfo]?
        package let totalTokens: Int?
        package let status: String
        package let invalidPaths: [String]?
        /// When `manage_selection` action=`list` and `include_content=true`
        package let blocks: [String]?
        /// Compact code-map summary for the current selection (no large content)
        package let codeStructure: SelectedCodeStructureDTO?
        package let fileSlices: [FileSliceDTO]?
        package let codemapAutoEnabled: Bool?
        package let summary: SelectionSummary?
        /// The active codemap usage mode: "auto", "complete", "selected", or "none"
        package let codeMapUsage: String?

        // MARK: - User Preset State Indicators (for virtual contexts)

        /// User's copy preset codemap mode (so builder knows user's actual view)
        package let userCopyCodeMapUsage: String?
        /// User's chat preset codemap mode
        package let userChatCodeMapUsage: String?
        /// Token count under user's copy preset settings
        package let userCopyTokens: Int?
        /// Token count under user's chat preset settings
        package let userChatTokens: Int?
        /// What this reply uses (e.g. "auto" for virtual contexts, nil if live)
        package let normalizedCodeMapUsage: String?
        /// Workspace token breakdown (total includes prompt, file tree, meta, git, etc.)
        package let tokenStats: TokenStats?
        /// Cache freshness and pending refresh state for token fields.
        package let tokenAccounting: TokenAccountingDTO?
        /// Summary of how selection would render under the effective copy preset (when it differs from auto)
        package let copyPresetProjection: CopyPresetProjectionSummaryDTO?

        /// Explicit initializer with tokenStats defaulting to nil for source compatibility
        package init(
            files: [SelectedFileInfo]?,
            totalTokens: Int?,
            status: String,
            invalidPaths: [String]? = nil,
            blocks: [String]? = nil,
            codeStructure: SelectedCodeStructureDTO? = nil,
            fileSlices: [FileSliceDTO]? = nil,
            codemapAutoEnabled: Bool? = nil,
            summary: SelectionSummary? = nil,
            codeMapUsage: String? = nil,
            userCopyCodeMapUsage: String? = nil,
            userChatCodeMapUsage: String? = nil,
            userCopyTokens: Int? = nil,
            userChatTokens: Int? = nil,
            normalizedCodeMapUsage: String? = nil,
            tokenStats: TokenStats? = nil,
            tokenAccounting: TokenAccountingDTO? = nil,
            copyPresetProjection: CopyPresetProjectionSummaryDTO? = nil
        ) {
            self.files = files
            self.totalTokens = totalTokens
            self.status = status
            self.invalidPaths = invalidPaths
            self.blocks = blocks
            self.codeStructure = codeStructure
            self.fileSlices = fileSlices
            self.codemapAutoEnabled = codemapAutoEnabled
            self.summary = summary
            self.codeMapUsage = codeMapUsage
            self.userCopyCodeMapUsage = userCopyCodeMapUsage
            self.userChatCodeMapUsage = userChatCodeMapUsage
            self.userCopyTokens = userCopyTokens
            self.userChatTokens = userChatTokens
            self.normalizedCodeMapUsage = normalizedCodeMapUsage
            self.tokenStats = tokenStats
            self.tokenAccounting = tokenAccounting
            self.copyPresetProjection = copyPresetProjection
        }

        private enum CodingKeys: String, CodingKey {
            case files
            case totalTokens = "total_tokens"
            case status
            case invalidPaths = "invalid_paths"
            case blocks
            case codeStructure = "code_structure"
            case fileSlices = "file_slices"
            case codemapAutoEnabled = "codemap_auto_enabled"
            case summary
            case codeMapUsage = "code_map_usage"
            case userCopyCodeMapUsage = "user_copy_codemap_usage"
            case userChatCodeMapUsage = "user_chat_codemap_usage"
            case userCopyTokens = "user_copy_tokens"
            case userChatTokens = "user_chat_tokens"
            case normalizedCodeMapUsage = "normalized_codemap_usage"
            case tokenStats = "token_stats"
            case tokenAccounting = "token_accounting"
            case copyPresetProjection = "copy_preset_projection"
        }
    }

    // MARK: - Read File

    /// Reply structure for read_file tool, carrying slice metadata
    package struct ReadFileReply: Codable, Equatable {
        package let content: String
        package let totalLines: Int
        package let firstLine: Int
        package let lastLine: Int
        package let message: String?
        package let displayPath: String?
        package let worktreeScope: WorktreeScopeDTO?
        package let errorMessage: String?
        package let errorCode: String?
        package let retryable: Bool?
        package let retryAfterMilliseconds: Int?

        package init(
            content: String,
            totalLines: Int,
            firstLine: Int,
            lastLine: Int,
            message: String? = nil,
            displayPath: String? = nil,
            worktreeScope: WorktreeScopeDTO? = nil,
            errorMessage: String? = nil,
            errorCode: String? = nil,
            retryable: Bool? = nil,
            retryAfterMilliseconds: Int? = nil
        ) {
            self.content = content
            self.totalLines = totalLines
            self.firstLine = firstLine
            self.lastLine = lastLine
            self.message = message
            self.displayPath = displayPath
            self.worktreeScope = worktreeScope
            self.errorMessage = errorMessage
            self.errorCode = errorCode
            self.retryable = retryable
            self.retryAfterMilliseconds = retryAfterMilliseconds
        }

        private enum CodingKeys: String, CodingKey {
            case content
            case totalLines = "total_lines"
            case firstLine = "first_line"
            case lastLine = "last_line"
            case message
            case displayPath = "display_path"
            case worktreeScope = "worktree_scope"
            case errorMessage = "error"
            case errorCode = "error_code"
            case retryable
            case retryAfterMilliseconds = "retry_after_ms"
        }
    }

    // MARK: - Apply Edits

    /// Compact summary returned by edit tools.
    ///
    /// Fields:
    /// - totalLinesChanged – sum of absolute line deltas across all committed chunks.
    /// - totalChunks       – number of diff chunks applied.
    package struct EditSummary: Codable, Equatable {
        package let status: String // "success", "partial", "failed"
        package let editsRequested: Int
        package let editsApplied: Int
        package let addedLines: Int?
        package let deletedLines: Int?
        package let totalLinesChanged: Int?
        package let totalChunks: Int?
        package let results: [EditOutcome]? // Provided by diff generator utilities
        package let unifiedDiff: String?
        let cardUnifiedDiff: String?
        // Extra context – used for friendlier UI and fallback reporting
        package let note: String?
        package let fileCreated: Bool?
        package let fileOverwritten: Bool?
        package let reviewStatus: String?
        package let rejectionReason: String?
        package let requiresUserApproval: Bool?
        package let errorMessage: String?
        package let errorCode: String?
        package let retryable: Bool?
        package let retryAfterMilliseconds: Int?
        package let suggestion: String?
        package let operationID: String?
        package let mutationState: String?
        package let freshness: String?

        package init(
            status: String,
            editsRequested: Int,
            editsApplied: Int,
            addedLines: Int?,
            deletedLines: Int?,
            totalLinesChanged: Int?,
            totalChunks: Int?,
            results: [EditOutcome]?,
            unifiedDiff: String?,
            cardUnifiedDiff: String?,
            note: String?,
            fileCreated: Bool?,
            fileOverwritten: Bool?,
            reviewStatus: String?,
            rejectionReason: String?,
            requiresUserApproval: Bool?,
            errorMessage: String? = nil,
            errorCode: String? = nil,
            retryable: Bool? = nil,
            retryAfterMilliseconds: Int? = nil,
            suggestion: String? = nil,
            operationID: String? = nil,
            mutationState: String? = nil,
            freshness: String? = nil
        ) {
            self.status = status
            self.editsRequested = editsRequested
            self.editsApplied = editsApplied
            self.addedLines = addedLines
            self.deletedLines = deletedLines
            self.totalLinesChanged = totalLinesChanged
            self.totalChunks = totalChunks
            self.results = results
            self.unifiedDiff = unifiedDiff
            self.cardUnifiedDiff = cardUnifiedDiff
            self.note = note
            self.fileCreated = fileCreated
            self.fileOverwritten = fileOverwritten
            self.reviewStatus = reviewStatus
            self.rejectionReason = rejectionReason
            self.requiresUserApproval = requiresUserApproval
            self.errorMessage = errorMessage
            self.errorCode = errorCode
            self.retryable = retryable
            self.retryAfterMilliseconds = retryAfterMilliseconds
            self.suggestion = suggestion
            self.operationID = operationID
            self.mutationState = mutationState
            self.freshness = freshness
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case editsRequested = "edits_requested"
            case editsApplied = "edits_applied"
            case addedLines = "added_lines"
            case deletedLines = "deleted_lines"
            case totalLinesChanged = "total_lines_changed"
            case totalChunks = "total_chunks"
            case results
            case unifiedDiff = "unified_diff"
            case cardUnifiedDiff = "card_unified_diff"
            case note
            case fileCreated = "file_created"
            case fileOverwritten = "file_overwritten"
            case reviewStatus = "review_status"
            case rejectionReason = "rejection_reason"
            case requiresUserApproval = "requires_user_approval"
            case errorMessage = "error"
            case errorCode = "error_code"
            case retryable
            case retryAfterMilliseconds = "retry_after_ms"
            case suggestion
            case operationID = "operation_id"
            case mutationState = "mutation_state"
            case freshness
        }
    }

    package struct ApplyPatchSummary: Codable, Equatable {
        package struct Change: Codable, Equatable {
            package let path: String
            let kind: String
            let movePath: String?
            let diff: String

            package init(
                path: String,
                kind: String,
                movePath: String?,
                diff: String
            ) {
                self.path = path
                self.kind = kind
                self.movePath = movePath
                self.diff = diff
            }

            private enum CodingKeys: String, CodingKey {
                case path
                case kind
                case movePath = "move_path"
                case diff
            }
        }

        package let status: String
        package let changes: [Change]
        package let output: String?
        package let changeCount: Int
        let summaryOnly: Bool?

        package init(
            status: String,
            changes: [Change],
            output: String?,
            changeCount: Int,
            summaryOnly: Bool?
        ) {
            self.status = status
            self.changes = changes
            self.output = output
            self.changeCount = changeCount
            self.summaryOnly = summaryOnly
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case changes
            case output
            case changeCount = "change_count"
            case summaryOnly = "summary_only"
        }
    }

    // MARK: - Cursor Native Edit

    package struct CursorNativeEditSummary: Decodable, Equatable {
        struct Content: Decodable, Equatable {
            let type: String?
            let path: String?
            let oldText: String?
            let newText: String?
            let unifiedDiff: String?
            let oldTextTruncated: Bool?
            let newTextTruncated: Bool?
            let diffTruncated: Bool?

            private enum CodingKeys: String, CodingKey {
                case type
                case path
                case oldText
                case newText
                case oldTextSnake = "old_text"
                case newTextSnake = "new_text"
                case unifiedDiff = "unified_diff"
                case cardUnifiedDiff = "card_unified_diff"
                case oldTextTruncated = "oldText_truncated"
                case newTextTruncated = "newText_truncated"
                case oldTextTruncatedSnake = "old_text_truncated"
                case newTextTruncatedSnake = "new_text_truncated"
                case oldTextTruncatedCamel = "oldTextTruncated"
                case newTextTruncatedCamel = "newTextTruncated"
                case diffTruncated = "diff_truncated"
                case diffTruncatedCamel = "diffTruncated"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try container.decodeIfPresent(String.self, forKey: .type)
                path = try container.decodeIfPresent(String.self, forKey: .path)
                oldText = try container.decodeIfPresent(String.self, forKey: .oldText)
                    ?? container.decodeIfPresent(String.self, forKey: .oldTextSnake)
                newText = try container.decodeIfPresent(String.self, forKey: .newText)
                    ?? container.decodeIfPresent(String.self, forKey: .newTextSnake)
                unifiedDiff = try container.decodeIfPresent(String.self, forKey: .unifiedDiff)
                    ?? container.decodeIfPresent(String.self, forKey: .cardUnifiedDiff)
                oldTextTruncated = try container.decodeIfPresent(Bool.self, forKey: .oldTextTruncated)
                    ?? container.decodeIfPresent(Bool.self, forKey: .oldTextTruncatedSnake)
                    ?? container.decodeIfPresent(Bool.self, forKey: .oldTextTruncatedCamel)
                newTextTruncated = try container.decodeIfPresent(Bool.self, forKey: .newTextTruncated)
                    ?? container.decodeIfPresent(Bool.self, forKey: .newTextTruncatedSnake)
                    ?? container.decodeIfPresent(Bool.self, forKey: .newTextTruncatedCamel)
                diffTruncated = try container.decodeIfPresent(Bool.self, forKey: .diffTruncated)
                    ?? container.decodeIfPresent(Bool.self, forKey: .diffTruncatedCamel)
            }
        }

        package let status: String?
        package let acpStatus: String?
        let kind: String?
        package let title: String?
        let content: [Content]?
        package let changeCount: Int?
        let summaryOnly: Bool?

        private enum CodingKeys: String, CodingKey {
            case status
            case acpStatus = "acp_status"
            case kind
            case title
            case content
            case changeCount = "change_count"
            case summaryOnly = "summary_only"
        }
    }

    // MARK: - Chat Send

    package struct ChatSendDTO: Codable, Equatable {
        package struct Diff: Codable, Equatable {
            let path: String
            let patch: String
        }

        /// Neutral request-budget echo for Oracle sends.
        package struct Usage: Codable, Equatable {
            package let inputTokens: Int
            package let contextWindow: Int?
            package let pct: Int?
            package let source: String?
            package let maxOutputTokens: Int?
            package let outputReserveTokens: Int?

            package init(
                inputTokens: Int,
                contextWindow: Int?,
                pct: Int?,
                source: String?,
                maxOutputTokens: Int?,
                outputReserveTokens: Int?
            ) {
                self.inputTokens = inputTokens
                self.contextWindow = contextWindow
                self.pct = pct
                self.source = source
                self.maxOutputTokens = maxOutputTokens
                self.outputReserveTokens = outputReserveTokens
            }

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case contextWindow = "context_window"
                case pct
                case source
                case maxOutputTokens = "max_output_tokens"
                case outputReserveTokens = "output_reserve_tokens"
            }
        }

        private struct ErrorPayload: Codable {
            let code: String?
            let message: String?
        }

        /// One `errors[]` entry: a legacy string, or the object persisted for failed Oracle
        /// summaries (`{code?, message, index?, lane_chat_id?}`). Decodes to its message text so an
        /// object entry never breaks decoding of the rest of the result.
        private struct ErrorEntry: Decodable {
            let text: String?

            init(from decoder: Decoder) throws {
                if let string = try? decoder.singleValueContainer().decode(String.self) {
                    text = string
                } else if let payload = try? ErrorPayload(from: decoder) {
                    text = payload.message ?? payload.code
                } else {
                    text = nil
                }
            }
        }

        package struct Pending: Codable, Equatable {
            package struct Progress: Codable, Equatable {
                package let outputChars: Int?
                package let lastActivitySecondsAgo: Int?
                package let queuePosition: Int?

                private enum CodingKeys: String, CodingKey {
                    case outputChars = "output_chars"
                    case lastActivitySecondsAgo = "last_activity_seconds_ago"
                    case queuePosition = "queue_position"
                }
            }

            let reason: String?
            package let streamState: String?
            let elapsedSeconds: Double?
            package let progress: Progress?

            private enum CodingKeys: String, CodingKey {
                case reason
                case streamState = "stream_state"
                case elapsedSeconds = "elapsed_seconds"
                case progress
            }
        }

        struct WaitPolicy: Codable, Equatable {
            let mode: String
            let timeoutSeconds: Double
            let parentFamily: String?

            private enum CodingKeys: String, CodingKey {
                case mode
                case timeoutSeconds = "timeout_seconds"
                case parentFamily = "parent_family"
            }
        }

        struct WaitSummary: Codable, Equatable {
            let result: String?
            let pendingOperationIDs: [String]?

            private enum CodingKeys: String, CodingKey {
                case result
                case pendingOperationIDs = "pending_operation_ids"
            }
        }

        struct Resume: Codable, Equatable {
            let op: String?
            let operationIDs: [String]?

            private enum CodingKeys: String, CodingKey {
                case op
                case operationIDs = "operation_ids"
            }
        }

        package let ok: Bool?
        package let status: String?
        let index: Int?
        package let operationID: String?
        let queryID: String?
        package let pending: Pending?
        let waitPolicy: WaitPolicy?
        package let results: [ChatSendDTO]?
        let wait: WaitSummary?
        let resume: Resume?
        package let cancel: String?
        let code: String?
        package let error: String?
        let note: String?
        let partialResponse: String?
        package let chatID: String?
        package let mode: String?
        package let response: String?
        package let diffs: [Diff]?
        package let errors: [String]?
        let modelID: String?
        package let modelName: String?
        /// App-only identity decoded from UI sidecars; never encoded onto the wire.
        let uiModelID: String?
        /// App-only display identity decoded from UI sidecars; never encoded onto the wire.
        package let uiModelName: String?
        let modelSelection: String?
        let modelSource: String?
        let modelPresetID: String?
        package let modelPresetName: String?
        let usage: Usage?

        private enum CodingKeys: String, CodingKey {
            case ok
            case status
            case index
            case operationID = "operation_id"
            case queryID = "query_id"
            case pending
            case waitPolicy = "wait_policy"
            case results
            case wait
            case resume
            case cancel
            case code
            case error
            case note
            case partialResponse = "partial_response"
            case chatID = "chat_id"
            case mode
            case response
            case diffs
            case patches
            case errors
            case modelID = "model_id"
            case modelName = "model_name"
            case uiModelID = "ui_model_id"
            case uiModelName = "ui_model_name"
            case modelSelection = "model_selection"
            case modelSource = "model_source"
            case modelPresetID = "model_preset_id"
            case modelPresetName = "model_preset_name"
            case usage
        }

        init(
            chatID: String?,
            mode: String?,
            response: String?,
            diffs: [Diff]?,
            errors: [String]?,
            ok: Bool? = nil,
            status: String? = nil,
            index: Int? = nil,
            operationID: String? = nil,
            queryID: String? = nil,
            pending: Pending? = nil,
            waitPolicy: WaitPolicy? = nil,
            results: [ChatSendDTO]? = nil,
            wait: WaitSummary? = nil,
            resume: Resume? = nil,
            cancel: String? = nil,
            code: String? = nil,
            error: String? = nil,
            note: String? = nil,
            partialResponse: String? = nil,
            modelID: String? = nil,
            modelName: String? = nil,
            uiModelID: String? = nil,
            uiModelName: String? = nil,
            modelSelection: String? = nil,
            modelSource: String? = nil,
            modelPresetID: String? = nil,
            modelPresetName: String? = nil,
            usage: Usage? = nil
        ) {
            self.ok = ok
            self.status = status
            self.index = index
            self.operationID = operationID
            self.queryID = queryID
            self.pending = pending
            self.waitPolicy = waitPolicy
            self.results = results
            self.wait = wait
            self.resume = resume
            self.cancel = cancel
            self.code = code
            self.error = error
            self.note = note
            self.partialResponse = partialResponse
            self.chatID = chatID
            self.mode = mode
            self.response = response
            self.diffs = diffs
            self.errors = errors
            self.modelID = modelID
            self.modelName = modelName
            self.uiModelID = uiModelID
            self.uiModelName = uiModelName
            self.modelSelection = modelSelection
            self.modelSource = modelSource
            self.modelPresetID = modelPresetID
            self.modelPresetName = modelPresetName
            self.usage = usage
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decodeIfPresent(Bool.self, forKey: .ok)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            index = try container.decodeIfPresent(Int.self, forKey: .index)
            operationID = try container.decodeIfPresent(String.self, forKey: .operationID)
            queryID = try container.decodeIfPresent(String.self, forKey: .queryID)
            pending = try container.decodeIfPresent(Pending.self, forKey: .pending)
            waitPolicy = try container.decodeIfPresent(WaitPolicy.self, forKey: .waitPolicy)
            results = try container.decodeIfPresent([ChatSendDTO].self, forKey: .results)
            wait = try container.decodeIfPresent(WaitSummary.self, forKey: .wait)
            resume = try container.decodeIfPresent(Resume.self, forKey: .resume)
            cancel = try container.decodeIfPresent(String.self, forKey: .cancel)
            let topLevelCode = try container.decodeIfPresent(String.self, forKey: .code)
            if let stringError = try? container.decode(String.self, forKey: .error) {
                code = topLevelCode
                error = stringError
            } else if let payload = try? container.decode(ErrorPayload.self, forKey: .error) {
                code = topLevelCode ?? payload.code
                error = payload.message ?? payload.code
            } else {
                code = topLevelCode
                error = nil
            }
            note = try container.decodeIfPresent(String.self, forKey: .note)
            partialResponse = try container.decodeIfPresent(String.self, forKey: .partialResponse)
            chatID = try container.decodeIfPresent(String.self, forKey: .chatID)
            mode = try container.decodeIfPresent(String.self, forKey: .mode)
            response = try container.decodeIfPresent(String.self, forKey: .response)
            if let decodedDiffs = try container.decodeIfPresent([Diff].self, forKey: .diffs) {
                diffs = decodedDiffs
            } else {
                diffs = try container.decodeIfPresent([Diff].self, forKey: .patches)
            }
            errors = try container.decodeIfPresent([ErrorEntry].self, forKey: .errors)?
                .compactMap(\.text)
            modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
            modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
            uiModelID = try container.decodeIfPresent(String.self, forKey: .uiModelID)
            uiModelName = try container.decodeIfPresent(String.self, forKey: .uiModelName)
            modelSelection = try container.decodeIfPresent(String.self, forKey: .modelSelection)
            modelSource = try container.decodeIfPresent(String.self, forKey: .modelSource)
            modelPresetID = try container.decodeIfPresent(String.self, forKey: .modelPresetID)
            modelPresetName = try container.decodeIfPresent(String.self, forKey: .modelPresetName)
            usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(ok, forKey: .ok)
            try container.encodeIfPresent(status, forKey: .status)
            try container.encodeIfPresent(index, forKey: .index)
            try container.encodeIfPresent(operationID, forKey: .operationID)
            try container.encodeIfPresent(queryID, forKey: .queryID)
            try container.encodeIfPresent(pending, forKey: .pending)
            try container.encodeIfPresent(waitPolicy, forKey: .waitPolicy)
            try container.encodeIfPresent(results, forKey: .results)
            try container.encodeIfPresent(wait, forKey: .wait)
            try container.encodeIfPresent(resume, forKey: .resume)
            try container.encodeIfPresent(cancel, forKey: .cancel)
            try container.encodeIfPresent(code, forKey: .code)
            try container.encodeIfPresent(error, forKey: .error)
            try container.encodeIfPresent(note, forKey: .note)
            try container.encodeIfPresent(partialResponse, forKey: .partialResponse)
            try container.encodeIfPresent(chatID, forKey: .chatID)
            try container.encodeIfPresent(mode, forKey: .mode)
            try container.encodeIfPresent(response, forKey: .response)
            try container.encodeIfPresent(diffs, forKey: .diffs)
            try container.encodeIfPresent(errors, forKey: .errors)
            if modelSource != "preset" {
                try container.encodeIfPresent(modelID, forKey: .modelID)
                try container.encodeIfPresent(modelName, forKey: .modelName)
            }
            try container.encodeIfPresent(modelSelection, forKey: .modelSelection)
            try container.encodeIfPresent(modelSource, forKey: .modelSource)
            try container.encodeIfPresent(modelPresetID, forKey: .modelPresetID)
            try container.encodeIfPresent(modelPresetName, forKey: .modelPresetName)
            try container.encodeIfPresent(usage, forKey: .usage)
        }
    }

    // MARK: - Context Builder

    package struct ContextBuilderDTO: Codable, Equatable {
        let tabID: String?
        package let status: String?
        let prompt: String?
        package let fileCount: Int?
        package let totalTokens: Int?
        package let selection: String?
        package let responseType: String?
        package let plan: ChatSendDTO?
        package let review: ChatSendDTO?
        let followUpHint: String?
        let message: String?
        let summary: String?

        private enum CodingKeys: String, CodingKey {
            case tabID = "context_id"
            case status
            case prompt
            case fileCount = "file_count"
            case totalTokens = "total_tokens"
            case selection
            case responseType = "response_type"
            case plan
            case review
            case followUpHint = "follow_up_hint"
            case message
            case summary
        }

        private enum LegacyCodingKeys: String, CodingKey {
            case tabID = "tab_id"
        }

        package init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)

            tabID = try container.decodeIfPresent(String.self, forKey: .tabID)
                ?? legacyContainer.decodeIfPresent(String.self, forKey: .tabID)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
            fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount)
            totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            selection = try container.decodeIfPresent(String.self, forKey: .selection)
            responseType = try container.decodeIfPresent(String.self, forKey: .responseType)
            plan = try container.decodeIfPresent(ChatSendDTO.self, forKey: .plan)
            review = try container.decodeIfPresent(ChatSendDTO.self, forKey: .review)
            followUpHint = try container.decodeIfPresent(String.self, forKey: .followUpHint)
            message = try container.decodeIfPresent(String.self, forKey: .message)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
        }
    }

    // MARK: - Models

    package struct SupportedModesInfo: Codable, Equatable {
        package let chat: Bool
        package let plan: Bool
        package let review: Bool

        package init(
            chat: Bool,
            plan: Bool,
            review: Bool
        ) {
            self.chat = chat
            self.plan = plan
            self.review = review
        }
    }

    package struct ModelInfo: Codable, Equatable {
        package let id: String
        package let name: String
        package let description: String?
        package let supportedModes: SupportedModesInfo?
        /// Neutral capability number; omit when unknown. Never paired with raw model identity for presets.
        package let contextWindow: Int?
        /// Neutral max-output number when readily available.
        package let maxOutputTokens: Int?

        package init(
            id: String,
            name: String,
            description: String? = nil,
            supportedModes: SupportedModesInfo? = nil,
            contextWindow: Int? = nil,
            maxOutputTokens: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.description = description
            self.supportedModes = supportedModes
            self.contextWindow = contextWindow
            self.maxOutputTokens = maxOutputTokens
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case description
            case supportedModes = "supported_modes"
            case contextWindow = "context_window"
            case maxOutputTokens = "max_output_tokens"
        }
    }

    package struct ListModelsReply: Codable, Equatable {
        package let models: [ModelInfo]
        package let total: Int
        package let notes: [String]?

        package init(models: [ModelInfo], total: Int, notes: [String]? = nil) {
            self.models = models
            self.total = total
            self.notes = notes
        }
    }

    // MARK: - File Actions

    package struct FileActionReply: Codable, Equatable {
        package let status: String // "ok" or error/other statuses
        package let action: String // "create", "delete", "move"
        package let path: String
        package let newPath: String? // present for move/rename
        package let warning: String?
        package let operationID: String?
        package let mutationState: String?
        package let freshness: String?
        package let errorMessage: String?
        package let errorCode: String?
        package let retryable: Bool?
        package let retryAfterMilliseconds: Int?
        package let suggestion: String?

        package init(
            status: String,
            action: String,
            path: String,
            newPath: String?,
            warning: String? = nil,
            operationID: String? = nil,
            mutationState: String? = nil,
            freshness: String? = nil,
            errorMessage: String? = nil,
            errorCode: String? = nil,
            retryable: Bool? = nil,
            retryAfterMilliseconds: Int? = nil,
            suggestion: String? = nil
        ) {
            self.status = status
            self.action = action
            self.path = path
            self.newPath = newPath
            self.warning = warning
            self.operationID = operationID
            self.mutationState = mutationState
            self.freshness = freshness
            self.errorMessage = errorMessage
            self.errorCode = errorCode
            self.retryable = retryable
            self.retryAfterMilliseconds = retryAfterMilliseconds
            self.suggestion = suggestion
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case action
            case path
            case newPath = "new_path"
            case warning
            case operationID = "operation_id"
            case mutationState = "mutation_state"
            case freshness
            case errorMessage = "error"
            case errorCode = "error_code"
            case retryable
            case retryAfterMilliseconds = "retry_after_ms"
            case suggestion
        }
    }

    // MARK: - Copy Preset DTOs

    /// Compact identifier for a copy preset
    package struct CopyPresetDescriptorDTO: Codable, Equatable {
        package let id: String // UUID string
        package let name: String
        package let kind: String? // CopyPresetKind.rawValue
        package let isBuiltIn: Bool

        package init(
            id: String,
            name: String,
            kind: String?,
            isBuiltIn: Bool
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.isBuiltIn = isBuiltIn
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case kind
            case isBuiltIn = "is_built_in"
        }
    }

    /// Full preset listing with configuration details
    package struct CopyPresetListItemDTO: Codable, Equatable {
        package let preset: CopyPresetDescriptorDTO
        package let description: String?
        package let icon: String?

        // Raw preset fields (may be nil meaning "uses workspace/UI defaults")
        package let includeFiles: Bool?
        let includeUserPrompt: Bool?
        let includeMetaPrompts: Bool?
        let includeFileTree: Bool?
        package let fileTreeMode: String? // "auto"|"full"|"selected"|"none"|nil
        package let codeMapUsage: String? // "auto"|"complete"|"selected"|"none"|nil
        package let gitInclusion: String? // "none"|"selected"|"complete"|nil

        package init(
            preset: CopyPresetDescriptorDTO,
            description: String?,
            icon: String?,
            includeFiles: Bool?,
            includeUserPrompt: Bool?,
            includeMetaPrompts: Bool?,
            includeFileTree: Bool?,
            fileTreeMode: String?,
            codeMapUsage: String?,
            gitInclusion: String?
        ) {
            self.preset = preset
            self.description = description
            self.icon = icon
            self.includeFiles = includeFiles
            self.includeUserPrompt = includeUserPrompt
            self.includeMetaPrompts = includeMetaPrompts
            self.includeFileTree = includeFileTree
            self.fileTreeMode = fileTreeMode
            self.codeMapUsage = codeMapUsage
            self.gitInclusion = gitInclusion
        }

        private enum CodingKeys: String, CodingKey {
            case preset
            case description
            case icon
            case includeFiles = "include_files"
            case includeUserPrompt = "include_user_prompt"
            case includeMetaPrompts = "include_meta_prompts"
            case includeFileTree = "include_file_tree"
            case fileTreeMode = "file_tree_mode"
            case codeMapUsage = "codemap_usage"
            case gitInclusion = "git_inclusion"
        }
    }

    /// Active vs effective preset context (for override scenarios)
    package struct CopyPresetContextDTO: Codable, Equatable {
        package let active: CopyPresetDescriptorDTO
        package let effective: CopyPresetDescriptorDTO // equals active if no override
        package let isOverridden: Bool

        package init(
            active: CopyPresetDescriptorDTO,
            effective: CopyPresetDescriptorDTO,
            isOverridden: Bool
        ) {
            self.active = active
            self.effective = effective
            self.isOverridden = isOverridden
        }

        private enum CodingKeys: String, CodingKey {
            case active
            case effective
            case isOverridden = "is_overridden"
        }
    }

    /// Summary of how selection would render under a copy preset
    package struct CopyPresetProjectionSummaryDTO: Codable, Equatable {
        let codeMapUsage: String
        let includesFiles: Bool
        let totalTokens: Int

        package init(
            codeMapUsage: String,
            includesFiles: Bool,
            totalTokens: Int
        ) {
            self.codeMapUsage = codeMapUsage
            self.includesFiles = includesFiles
            self.totalTokens = totalTokens
        }

        private enum CodingKeys: String, CodingKey {
            case codeMapUsage = "codemap_usage"
            case includesFiles = "includes_files"
            case totalTokens = "total_tokens"
        }
    }

    // MARK: - Unified prompt + selection + context (codemaps-first)

    package struct TokenAccountingDTO: Codable, Equatable {
        package let status: String
        package let source: String
        package let refreshPending: Bool
        package let incompleteComponents: [String]?

        package init(
            status: String,
            source: String,
            refreshPending: Bool,
            incompleteComponents: [String]? = nil
        ) {
            self.status = status
            self.source = source
            self.refreshPending = refreshPending
            self.incompleteComponents = incompleteComponents
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case source
            case refreshPending = "refresh_pending"
            case incompleteComponents = "incomplete_components"
        }
    }

    package struct TokenStats: Codable, Equatable {
        package let total: Int
        package let files: Int
        package let prompt: Int?
        package let fileTree: Int?
        package let meta: Int?
        package let git: Int?
        let other: Int?
        /// Token count from full files and slices (excludes codemaps)
        package let filesContent: Int?
        /// Token count from codemaps only
        package let codemaps: Int?

        package init(
            total: Int,
            files: Int,
            prompt: Int? = nil,
            fileTree: Int? = nil,
            meta: Int? = nil,
            git: Int? = nil,
            other: Int? = nil,
            filesContent: Int? = nil,
            codemaps: Int? = nil
        ) {
            self.total = total
            self.files = files
            self.prompt = prompt
            self.fileTree = fileTree
            self.meta = meta
            self.git = git
            self.other = other
            self.filesContent = filesContent
            self.codemaps = codemaps
        }

        private enum CodingKeys: String, CodingKey {
            case total
            case files
            case prompt
            case fileTree = "file_tree"
            case meta
            case git
            case other
            case filesContent = "files_content"
            case codemaps
        }
    }

    // MARK: - Prompt (read/write)

    package struct PromptReply: Codable, Equatable {
        package let prompt: String
        package let lines: Int

        // Preset information
        package let copyPresetName: String?
        package let chatPresetName: String?
        package let chatMode: String? // "chat", "plan", "review"

        // Configuration breakdown (what's included in the prompt)
        package let includesFiles: Bool?
        package let includesFileTree: Bool?
        package let includesCodemaps: Bool?
        package let includesGitDiff: Bool?
        package let includesUserPrompt: Bool?
        package let includesMetaPrompts: Bool?
        package let includesStoredPrompts: Bool?

        // Detailed settings
        package let fileTreeMode: String? // "auto", "full", "selected", "none"
        package let codeMapUsage: String? // "none", "auto", "complete", "selected"
        package let gitInclusion: String? // "none", "selected", "complete"

        // Token counts
        package let effectiveTokens: Int? // Tokens for the actual prompt being sent
        package let fullFilesTokens: Int? // Tokens if full files were included

        // Codemap details (when codemaps are included)
        package let codeMapFileCount: Int? // Number of files with codemaps
        package let codeMapTokens: Int? // Tokens consumed by codemaps
        let codeMapFiles: [String]? // List of file paths with codemaps

        package init(
            prompt: String,
            lines: Int,
            copyPresetName: String?,
            chatPresetName: String?,
            chatMode: String?,
            includesFiles: Bool?,
            includesFileTree: Bool?,
            includesCodemaps: Bool?,
            includesGitDiff: Bool?,
            includesUserPrompt: Bool?,
            includesMetaPrompts: Bool?,
            includesStoredPrompts: Bool?,
            fileTreeMode: String?,
            codeMapUsage: String?,
            gitInclusion: String?,
            effectiveTokens: Int?,
            fullFilesTokens: Int?,
            codeMapFileCount: Int?,
            codeMapTokens: Int?,
            codeMapFiles: [String]?
        ) {
            self.prompt = prompt
            self.lines = lines
            self.copyPresetName = copyPresetName
            self.chatPresetName = chatPresetName
            self.chatMode = chatMode
            self.includesFiles = includesFiles
            self.includesFileTree = includesFileTree
            self.includesCodemaps = includesCodemaps
            self.includesGitDiff = includesGitDiff
            self.includesUserPrompt = includesUserPrompt
            self.includesMetaPrompts = includesMetaPrompts
            self.includesStoredPrompts = includesStoredPrompts
            self.fileTreeMode = fileTreeMode
            self.codeMapUsage = codeMapUsage
            self.gitInclusion = gitInclusion
            self.effectiveTokens = effectiveTokens
            self.fullFilesTokens = fullFilesTokens
            self.codeMapFileCount = codeMapFileCount
            self.codeMapTokens = codeMapTokens
            self.codeMapFiles = codeMapFiles
        }

        private enum CodingKeys: String, CodingKey {
            case prompt
            case lines
            case copyPresetName = "copy_preset_name"
            case chatPresetName = "chat_preset_name"
            case chatMode = "chat_mode"
            case includesFiles = "includes_files"
            case includesFileTree = "includes_file_tree"
            case includesCodemaps = "includes_codemaps"
            case includesGitDiff = "includes_git_diff"
            case includesUserPrompt = "includes_user_prompt"
            case includesMetaPrompts = "includes_meta_prompts"
            case includesStoredPrompts = "includes_stored_prompts"
            case fileTreeMode = "file_tree_mode"
            case codeMapUsage = "codemap_usage"
            case gitInclusion = "git_inclusion"
            case effectiveTokens = "effective_tokens"
            case fullFilesTokens = "full_files_tokens"
            case codeMapFileCount = "codemap_file_count"
            case codeMapTokens = "codemap_tokens"
            case codeMapFiles = "codemap_files"
        }
    }

    // MARK: - Prompt Export

    package struct PromptExportReply: Codable, Equatable {
        package let path: String
        package let tokens: Int
        package let bytes: Int
        package let files: [SelectedFileInfo]
        /// The copy preset used for this export (if overridden or for informational purposes)
        package let copyPreset: CopyPresetDescriptorDTO?

        package init(
            path: String,
            tokens: Int,
            bytes: Int,
            files: [SelectedFileInfo],
            copyPreset: CopyPresetDescriptorDTO?
        ) {
            self.path = path
            self.tokens = tokens
            self.bytes = bytes
            self.files = files
            self.copyPreset = copyPreset
        }

        private enum CodingKeys: String, CodingKey {
            case path
            case tokens
            case bytes
            case files
            case copyPreset = "copy_preset"
        }
    }

    /// Reply for list_presets operation
    package struct PresetsListReply: Codable, Equatable {
        package let presets: [CopyPresetListItemDTO]
    }

    // MARK: - Worktree Management Tool

    package struct ManageWorktreeReplyDTO: Codable, Equatable {
        package let op: String
        package let repository: RepositoryDTO?
        let repositories: [RepositoryDTO]?
        package let worktree: WorktreeDTO?
        package let worktrees: [WorktreeDTO]?
        package let createdWorktree: WorktreeDTO?
        package let binding: BindingDTO?
        package let bindings: [BindingDTO]?
        package let previousBinding: BindingDTO?
        package let graph: GraphDTO?
        package let merge: MergeDTO?
        package let warning: String?
        package let error: String?

        package init(
            op: String,
            repository: RepositoryDTO? = nil,
            repositories: [RepositoryDTO]? = nil,
            worktree: WorktreeDTO? = nil,
            worktrees: [WorktreeDTO]? = nil,
            createdWorktree: WorktreeDTO? = nil,
            binding: BindingDTO? = nil,
            bindings: [BindingDTO]? = nil,
            previousBinding: BindingDTO? = nil,
            graph: GraphDTO? = nil,
            merge: MergeDTO? = nil,
            warning: String? = nil,
            error: String? = nil
        ) {
            self.op = op
            self.repository = repository
            self.repositories = repositories
            self.worktree = worktree
            self.worktrees = worktrees
            self.createdWorktree = createdWorktree
            self.binding = binding
            self.bindings = bindings
            self.previousBinding = previousBinding
            self.graph = graph
            self.merge = merge
            self.warning = warning
            self.error = error
        }

        private enum CodingKeys: String, CodingKey {
            case op, repository, repositories, worktree, worktrees, binding, bindings, graph, merge, warning, error
            case createdWorktree = "created_worktree"
            case previousBinding = "previous_binding"
        }

        package struct RepositoryDTO: Codable, Equatable {
            package let repositoryID: String?
            package let repoKey: String
            package let displayName: String
            package let rootPath: String
            let commonGitDir: String?
            let mainWorktreeRoot: String?

            package init(
                repositoryID: String?,
                repoKey: String,
                displayName: String,
                rootPath: String,
                commonGitDir: String?,
                mainWorktreeRoot: String?
            ) {
                self.repositoryID = repositoryID
                self.repoKey = repoKey
                self.displayName = displayName
                self.rootPath = rootPath
                self.commonGitDir = commonGitDir
                self.mainWorktreeRoot = mainWorktreeRoot
            }

            private enum CodingKeys: String, CodingKey {
                case repositoryID = "repository_id"
                case repoKey = "repo_key"
                case displayName = "display_name"
                case rootPath = "root_path"
                case commonGitDir = "common_git_dir"
                case mainWorktreeRoot = "main_worktree_root"
            }
        }

        package struct WorktreeDTO: Codable, Equatable {
            package let worktreeID: String
            package let specifier: String
            package let path: String
            let gitDir: String?
            let name: String?
            package let branch: String?
            package let head: String?
            package let isMain: Bool
            let isCurrent: Bool
            package let isDetached: Bool
            package let isLocked: Bool
            package let lockReason: String?
            package let isPrunable: Bool
            package let prunableReason: String?
            package let visual: VisualIdentityDTO?
            package let status: StatusDTO?

            package init(
                worktreeID: String,
                specifier: String,
                path: String,
                gitDir: String?,
                name: String?,
                branch: String?,
                head: String?,
                isMain: Bool,
                isCurrent: Bool,
                isDetached: Bool,
                isLocked: Bool,
                lockReason: String?,
                isPrunable: Bool,
                prunableReason: String?,
                visual: VisualIdentityDTO?,
                status: StatusDTO?
            ) {
                self.worktreeID = worktreeID
                self.specifier = specifier
                self.path = path
                self.gitDir = gitDir
                self.name = name
                self.branch = branch
                self.head = head
                self.isMain = isMain
                self.isCurrent = isCurrent
                self.isDetached = isDetached
                self.isLocked = isLocked
                self.lockReason = lockReason
                self.isPrunable = isPrunable
                self.prunableReason = prunableReason
                self.visual = visual
                self.status = status
            }

            private enum CodingKeys: String, CodingKey {
                case worktreeID = "worktree_id"
                case specifier, path
                case gitDir = "git_dir"
                case name, branch, head
                case isMain = "is_main"
                case isCurrent = "is_current"
                case isDetached = "is_detached"
                case isLocked = "is_locked"
                case lockReason = "lock_reason"
                case isPrunable = "is_prunable"
                case prunableReason = "prunable_reason"
                case visual, status
            }
        }

        package struct VisualIdentityDTO: Codable, Equatable {
            package let label: String?
            package let colorHex: String
            package let iconName: String
            package let markerStyle: String

            package init(
                label: String?,
                colorHex: String,
                iconName: String,
                markerStyle: String
            ) {
                self.label = label
                self.colorHex = colorHex
                self.iconName = iconName
                self.markerStyle = markerStyle
            }

            private enum CodingKeys: String, CodingKey {
                case label
                case colorHex = "color_hex"
                case iconName = "icon_name"
                case markerStyle = "marker_style"
            }
        }

        package struct StatusDTO: Codable, Equatable {
            package let staged: Int
            package let modified: Int
            package let untracked: Int
            package let isDirty: Bool

            package init(
                staged: Int,
                modified: Int,
                untracked: Int,
                isDirty: Bool
            ) {
                self.staged = staged
                self.modified = modified
                self.untracked = untracked
                self.isDirty = isDirty
            }

            private enum CodingKeys: String, CodingKey {
                case staged, modified, untracked
                case isDirty = "is_dirty"
            }
        }

        package struct BindingDTO: Codable, Equatable {
            let id: String
            let repositoryID: String
            let repoKey: String
            package let logicalRootPath: String
            package let logicalRootName: String?
            package let worktreeID: String
            package let worktreeRootPath: String
            let worktreeName: String?
            package let branch: String?
            let head: String?
            package let visualLabel: String?
            package let visualColorHex: String?
            let boundAt: String
            package let source: String

            package init(
                id: String,
                repositoryID: String,
                repoKey: String,
                logicalRootPath: String,
                logicalRootName: String?,
                worktreeID: String,
                worktreeRootPath: String,
                worktreeName: String?,
                branch: String?,
                head: String?,
                visualLabel: String?,
                visualColorHex: String?,
                boundAt: String,
                source: String
            ) {
                self.id = id
                self.repositoryID = repositoryID
                self.repoKey = repoKey
                self.logicalRootPath = logicalRootPath
                self.logicalRootName = logicalRootName
                self.worktreeID = worktreeID
                self.worktreeRootPath = worktreeRootPath
                self.worktreeName = worktreeName
                self.branch = branch
                self.head = head
                self.visualLabel = visualLabel
                self.visualColorHex = visualColorHex
                self.boundAt = boundAt
                self.source = source
            }

            private enum CodingKeys: String, CodingKey {
                case id
                case repositoryID = "repository_id"
                case repoKey = "repo_key"
                case logicalRootPath = "logical_root_path"
                case logicalRootName = "logical_root_name"
                case worktreeID = "worktree_id"
                case worktreeRootPath = "worktree_root_path"
                case worktreeName = "worktree_name"
                case branch, head
                case visualLabel = "visual_label"
                case visualColorHex = "visual_color_hex"
                case boundAt = "bound_at"
                case source
            }
        }

        package struct GraphDTO: Codable, Equatable {
            let requested: Bool
            package let limit: Int
            package let lines: [String]
            let lineCount: Int
            let truncated: Bool
            package let source: String?

            package init(
                requested: Bool,
                limit: Int,
                lines: [String],
                lineCount: Int? = nil,
                truncated: Bool = false,
                source: String? = nil
            ) {
                self.requested = requested
                self.limit = limit
                self.lines = lines
                self.lineCount = lineCount ?? lines.count
                self.truncated = truncated
                self.source = source
            }

            package init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                requested = try container.decode(Bool.self, forKey: .requested)
                limit = try container.decode(Int.self, forKey: .limit)
                lines = try container.decode([String].self, forKey: .lines)
                lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount) ?? lines.count
                truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
                source = try container.decodeIfPresent(String.self, forKey: .source)
            }

            private enum CodingKeys: String, CodingKey {
                case requested, limit, lines, truncated, source
                case lineCount = "line_count"
            }
        }

        package struct MergeDTO: Codable, Equatable {
            package let status: String
            package let operationID: String?
            package let sessionID: String?
            package let source: EndpointDTO?
            package let target: EndpointDTO?
            let mergeBase: String?
            package let sourceHead: String?
            package let targetHeadBefore: String?
            package let targetHeadAfter: String?
            package let mergeCommit: String?
            package let visualization: VisualizationDTO?
            package let preflight: PreflightDTO?
            package let summary: SummaryDTO?
            package let artifacts: ArtifactsDTO?
            package let conflictFiles: [String]?
            package let staleReason: String?
            package let errorCode: String?
            package let error: String?
            package let postMerge: String?
            package let sourceWorktreeStatus: String?
            package let nextActions: [String]

            package init(
                status: String,
                operationID: String? = nil,
                sessionID: String? = nil,
                source: EndpointDTO? = nil,
                target: EndpointDTO? = nil,
                mergeBase: String? = nil,
                sourceHead: String? = nil,
                targetHeadBefore: String? = nil,
                targetHeadAfter: String? = nil,
                mergeCommit: String? = nil,
                visualization: VisualizationDTO? = nil,
                preflight: PreflightDTO? = nil,
                summary: SummaryDTO? = nil,
                artifacts: ArtifactsDTO? = nil,
                conflictFiles: [String]? = nil,
                staleReason: String? = nil,
                errorCode: String? = nil,
                error: String? = nil,
                postMerge: String? = nil,
                sourceWorktreeStatus: String? = nil,
                nextActions: [String] = []
            ) {
                self.status = status
                self.operationID = operationID
                self.sessionID = sessionID
                self.source = source
                self.target = target
                self.mergeBase = mergeBase
                self.sourceHead = sourceHead
                self.targetHeadBefore = targetHeadBefore
                self.targetHeadAfter = targetHeadAfter
                self.mergeCommit = mergeCommit
                self.visualization = visualization
                self.preflight = preflight
                self.summary = summary
                self.artifacts = artifacts
                self.conflictFiles = conflictFiles
                self.staleReason = staleReason
                self.errorCode = errorCode
                self.error = error
                self.postMerge = postMerge
                self.sourceWorktreeStatus = sourceWorktreeStatus
                self.nextActions = nextActions
            }

            private enum CodingKeys: String, CodingKey {
                case status, source, target, visualization, preflight, summary, artifacts, error
                case operationID = "operation_id"
                case sessionID = "session_id"
                case mergeBase = "merge_base"
                case sourceHead = "source_head"
                case targetHeadBefore = "target_head_before"
                case targetHeadAfter = "target_head_after"
                case mergeCommit = "merge_commit"
                case conflictFiles = "conflict_files"
                case staleReason = "stale_reason"
                case errorCode = "error_code"
                case postMerge = "post_merge"
                case sourceWorktreeStatus = "source_worktree_status"
                case nextActions = "next_actions"
            }

            package struct EndpointDTO: Codable, Equatable {
                package let worktreeID: String
                let repoKey: String
                package let path: String
                let name: String?
                package let branch: String?
                let head: String
                package let shortHead: String
                let isMain: Bool
                package let label: String

                package init(
                    worktreeID: String,
                    repoKey: String,
                    path: String,
                    name: String?,
                    branch: String?,
                    head: String,
                    shortHead: String,
                    isMain: Bool,
                    label: String
                ) {
                    self.worktreeID = worktreeID
                    self.repoKey = repoKey
                    self.path = path
                    self.name = name
                    self.branch = branch
                    self.head = head
                    self.shortHead = shortHead
                    self.isMain = isMain
                    self.label = label
                }

                private enum CodingKeys: String, CodingKey {
                    case worktreeID = "worktree_id"
                    case repoKey = "repo_key"
                    case path, name, branch, head
                    case shortHead = "short_head"
                    case isMain = "is_main"
                    case label
                }
            }

            package struct VisualizationDTO: Codable, Equatable {
                let requested: Bool
                package let limit: Int
                package let text: String
                package let lines: [String]
                let lineCount: Int
                package let truncated: Bool
                let sourceWorktreeID: String?
                let targetWorktreeID: String?
                let source: String?

                package init(
                    requested: Bool,
                    limit: Int,
                    text: String,
                    lines: [String],
                    lineCount: Int? = nil,
                    truncated: Bool = false,
                    sourceWorktreeID: String? = nil,
                    targetWorktreeID: String? = nil,
                    source: String? = nil
                ) {
                    self.requested = requested
                    self.limit = limit
                    self.text = text
                    self.lines = lines
                    self.lineCount = lineCount ?? lines.count
                    self.truncated = truncated
                    self.sourceWorktreeID = sourceWorktreeID
                    self.targetWorktreeID = targetWorktreeID
                    self.source = source
                }

                private enum CodingKeys: String, CodingKey {
                    case requested, limit, text, lines, truncated, source
                    case lineCount = "line_count"
                    case sourceWorktreeID = "source_worktree_id"
                    case targetWorktreeID = "target_worktree_id"
                }
            }

            package struct PreflightDTO: Codable, Equatable {
                package let blocked: Bool
                package let blockers: [BlockerDTO]
                package let conflictPrediction: ConflictPredictionDTO?

                package init(
                    blocked: Bool,
                    blockers: [BlockerDTO],
                    conflictPrediction: ConflictPredictionDTO?
                ) {
                    self.blocked = blocked
                    self.blockers = blockers
                    self.conflictPrediction = conflictPrediction
                }

                private enum CodingKeys: String, CodingKey {
                    case blocked, blockers
                    case conflictPrediction = "conflict_prediction"
                }
            }

            package struct BlockerDTO: Codable, Equatable {
                package let code: String
                package let message: String
                package let paths: [String]

                package init(
                    code: String,
                    message: String,
                    paths: [String]
                ) {
                    self.code = code
                    self.message = message
                    self.paths = paths
                }
            }

            package struct ConflictPredictionDTO: Codable, Equatable {
                package let status: String
                package let files: [String]
                package let message: String?

                package init(
                    status: String,
                    files: [String],
                    message: String?
                ) {
                    self.status = status
                    self.files = files
                    self.message = message
                }
            }

            package struct SummaryDTO: Codable, Equatable {
                package let commits: Int
                package let files: Int
                package let insertions: Int
                package let deletions: Int

                package init(
                    commits: Int,
                    files: Int,
                    insertions: Int,
                    deletions: Int
                ) {
                    self.commits = commits
                    self.files = files
                    self.insertions = insertions
                    self.deletions = deletions
                }
            }

            package struct ArtifactsDTO: Codable, Equatable {
                package let snapshotID: String
                package let snapshotDirectory: String
                let manifestPath: String
                package let mapPath: String
                package let allPatchPath: String?
                package let sidecarPath: String

                package init(
                    snapshotID: String,
                    snapshotDirectory: String,
                    manifestPath: String,
                    mapPath: String,
                    allPatchPath: String?,
                    sidecarPath: String
                ) {
                    self.snapshotID = snapshotID
                    self.snapshotDirectory = snapshotDirectory
                    self.manifestPath = manifestPath
                    self.mapPath = mapPath
                    self.allPatchPath = allPatchPath
                    self.sidecarPath = sidecarPath
                }

                private enum CodingKeys: String, CodingKey {
                    case snapshotID = "snapshot_id"
                    case snapshotDirectory = "snapshot_directory"
                    case manifestPath = "manifest_path"
                    case mapPath = "map_path"
                    case allPatchPath = "all_patch_path"
                    case sidecarPath = "sidecar_path"
                }
            }
        }
    }

    // MARK: - Unified Git Tool

    /// Main reply DTO for the unified `git` MCP tool.
    /// The `op` field indicates which operation was performed and which
    /// payload fields are populated.
    ///
    /// Multi-root support:
    /// - When operating on a single repo, the existing flat structure is used (status, diff, log, etc.)
    /// - When operating on multiple repos, the `repos` array contains per-repo results
    /// - The `aggregate` field contains combined totals across all repos (for multi-root diff)
    package struct GitToolReplyDTO: Codable, Equatable {
        package let op: String

        /// Multi-root support
        /// Per-repo results for multi-root operations (nil when single repo)
        package let repos: [RepoResultDTO]?
        /// Aggregated results across all repos (for multi-root diff operations)
        package let aggregate: AggregateDTO?

        /// Status op payload (single repo)
        package let status: StatusDTO?

        /// Diff op payload (single repo)
        package let diff: DiffDTO?

        /// Log op payload (single repo)
        package let log: LogDTO?

        /// Show op payload (single repo)
        package let show: ShowDTO?

        /// Blame op payload (single repo)
        package let blame: BlameDTO?

        /// Worktree metadata (single repo)
        package let worktree: WorktreeDTO?

        // Artifact info (diff with artifacts: true)
        package let snapshotId: String?
        package let snapshotDir: String?

        package let artifacts: ArtifactsDTO?
        package let primaryArtifacts: PrimaryArtifactsDTO?
        let summary: SummaryDTO?
        package let oneliner: String?
        package let inputs: DiffInputsDTO?
        package let modeDetails: String?
        package let inline: InlineDTO?

        // Common
        package let warning: String?
        package let emptyReason: String?
        package let error: String?

        private enum CodingKeys: String, CodingKey {
            case op, repos, aggregate, status, diff, log, show, blame, worktree
            case artifacts, summary, oneliner, inputs, inline, warning, error
            case primaryArtifacts = "primary_artifacts"
            case snapshotId = "snapshot_id"
            case snapshotDir = "snapshot_dir"

            case modeDetails = "mode_details"
            case emptyReason = "empty_reason"
        }

        /// Explicit initializer to allow default values for new optional fields
        package init(
            op: String,
            repos: [RepoResultDTO]? = nil,
            aggregate: AggregateDTO? = nil,
            status: StatusDTO? = nil,
            diff: DiffDTO? = nil,
            log: LogDTO? = nil,
            show: ShowDTO? = nil,
            blame: BlameDTO? = nil,
            worktree: WorktreeDTO? = nil,
            snapshotId: String? = nil,
            snapshotDir: String? = nil,
            artifacts: ArtifactsDTO? = nil,
            primaryArtifacts: PrimaryArtifactsDTO? = nil,
            summary: SummaryDTO? = nil,
            oneliner: String? = nil,
            inputs: DiffInputsDTO? = nil,
            modeDetails: String? = nil,
            inline: InlineDTO? = nil,
            warning: String? = nil,
            emptyReason: String? = nil,
            error: String? = nil
        ) {
            self.op = op
            self.repos = repos
            self.aggregate = aggregate
            self.status = status
            self.diff = diff
            self.log = log
            self.show = show
            self.blame = blame
            self.worktree = worktree
            self.snapshotId = snapshotId
            self.snapshotDir = snapshotDir
            self.artifacts = artifacts
            self.primaryArtifacts = primaryArtifacts
            self.summary = summary
            self.oneliner = oneliner
            self.inputs = inputs
            self.modeDetails = modeDetails
            self.inline = inline
            self.warning = warning
            self.emptyReason = emptyReason
            self.error = error
        }

        // MARK: - Nested DTOs

        // MARK: Multi-root DTOs

        /// Per-repo result for multi-root operations
        package struct RepoResultDTO: Codable, Equatable {
            /// Canonical absolute path of the git repository root
            package let repoRoot: String
            /// Stable repo key for storage/identification
            package let repoKey: String
            /// Human-readable repo name (typically last path component)
            package let repoName: String?

            // Op-specific payloads (at most one populated per repo)
            package let status: StatusDTO?
            package let diff: DiffDTO?
            package let log: LogDTO?
            package let show: ShowDTO?
            package let blame: BlameDTO?

            /// Worktree metadata (per repo)
            package let worktree: WorktreeDTO?

            // Artifact info (for diff with artifacts)
            package let snapshotId: String?
            package let snapshotDir: String?
            package let artifacts: ArtifactsDTO?
            package let primaryArtifacts: PrimaryArtifactsDTO?
            package let summary: SummaryDTO?
            package let oneliner: String?
            package let inputs: DiffInputsDTO?
            package let modeDetails: String?
            package let inline: InlineDTO?

            // Per-repo status
            package let warning: String?
            package let emptyReason: String?
            package let error: String?

            private enum CodingKeys: String, CodingKey {
                case repoRoot = "repo_root"
                case repoKey = "repo_key"
                case repoName = "repo_name"
                case status, diff, log, show, blame, worktree
                case snapshotId = "snapshot_id"
                case snapshotDir = "snapshot_dir"
                case artifacts, summary, oneliner, inputs
                case primaryArtifacts = "primary_artifacts"
                case modeDetails = "mode_details"
                case inline
                case warning
                case emptyReason = "empty_reason"
                case error
            }

            package init(
                repoRoot: String,
                repoKey: String,
                repoName: String? = nil,
                status: StatusDTO? = nil,
                diff: DiffDTO? = nil,
                log: LogDTO? = nil,
                show: ShowDTO? = nil,
                blame: BlameDTO? = nil,
                worktree: WorktreeDTO? = nil,
                snapshotId: String? = nil,
                snapshotDir: String? = nil,
                artifacts: ArtifactsDTO? = nil,
                primaryArtifacts: PrimaryArtifactsDTO? = nil,
                summary: SummaryDTO? = nil,
                oneliner: String? = nil,
                inputs: DiffInputsDTO? = nil,
                modeDetails: String? = nil,
                inline: InlineDTO? = nil,
                warning: String? = nil,
                emptyReason: String? = nil,
                error: String? = nil
            ) {
                self.repoRoot = repoRoot
                self.repoKey = repoKey
                self.repoName = repoName
                self.status = status
                self.diff = diff
                self.log = log
                self.show = show
                self.blame = blame
                self.worktree = worktree
                self.snapshotId = snapshotId
                self.snapshotDir = snapshotDir
                self.artifacts = artifacts
                self.primaryArtifacts = primaryArtifacts
                self.summary = summary
                self.oneliner = oneliner
                self.inputs = inputs
                self.modeDetails = modeDetails
                self.inline = inline
                self.warning = warning
                self.emptyReason = emptyReason
                self.error = error
            }
        }

        /// Aggregated results across multiple repos (for multi-root diff)
        package struct AggregateDTO: Codable, Equatable {
            /// Combined totals across all repos
            package let totals: TotalsDTO?
            /// Combined status breakdown across all repos
            package let byStatus: [String: Int]?
            /// Summary one-liner (e.g., "3 repos: 15 files (+200 -50)")
            package let oneliner: String?
            /// Number of repos included in aggregation
            package let repoCount: Int?

            package init(
                totals: TotalsDTO? = nil,
                byStatus: [String: Int]? = nil,
                oneliner: String? = nil,
                repoCount: Int? = nil
            ) {
                self.totals = totals
                self.byStatus = byStatus
                self.oneliner = oneliner
                self.repoCount = repoCount
            }

            private enum CodingKeys: String, CodingKey {
                case totals
                case byStatus = "by_status"
                case oneliner
                case repoCount = "repo_count"
            }
        }

        package struct WorktreeDTO: Codable, Equatable {
            package let isWorktree: Bool
            package let worktreeName: String?
            let worktreeRoot: String
            let commonGitDir: String?
            package let mainWorktreeRoot: String?
            package let worktreeBranch: String?
            package let mainBranch: String?
            package let worktreeHead: String?
            package let mainHead: String?

            package init(
                isWorktree: Bool,
                worktreeName: String?,
                worktreeRoot: String,
                commonGitDir: String?,
                mainWorktreeRoot: String?,
                worktreeBranch: String?,
                mainBranch: String?,
                worktreeHead: String?,
                mainHead: String?
            ) {
                self.isWorktree = isWorktree
                self.worktreeName = worktreeName
                self.worktreeRoot = worktreeRoot
                self.commonGitDir = commonGitDir
                self.mainWorktreeRoot = mainWorktreeRoot
                self.worktreeBranch = worktreeBranch
                self.mainBranch = mainBranch
                self.worktreeHead = worktreeHead
                self.mainHead = mainHead
            }

            private enum CodingKeys: String, CodingKey {
                case isWorktree = "is_worktree"
                case worktreeName = "worktree_name"
                case worktreeRoot = "worktree_root"
                case commonGitDir = "common_git_dir"
                case mainWorktreeRoot = "main_worktree_root"
                case worktreeBranch = "worktree_branch"
                case mainBranch = "main_branch"
                case worktreeHead = "worktree_head"
                case mainHead = "main_head"
            }
        }

        package struct StatusDTO: Codable, Equatable {
            package let branch: String?
            package let upstream: String?
            package let ahead: Int?
            package let behind: Int?
            package let staged: [String]
            package let modified: [String]
            package let untracked: [String]
            let summary: String

            package init(
                branch: String?,
                upstream: String?,
                ahead: Int?,
                behind: Int?,
                staged: [String],
                modified: [String],
                untracked: [String],
                summary: String
            ) {
                self.branch = branch
                self.upstream = upstream
                self.ahead = ahead
                self.behind = behind
                self.staged = staged
                self.modified = modified
                self.untracked = untracked
                self.summary = summary
            }

            private enum CodingKeys: String, CodingKey {
                case branch, upstream, ahead, behind, staged, modified, untracked, summary
            }
        }

        package struct DiffDTO: Codable, Equatable {
            package let compare: String
            package let detail: String?
            package let files: [DiffFileDTO]?
            package let totals: TotalsDTO
            package let byStatus: [String: Int]?
            package let oneliner: String
            package let truncated: Bool?
            package let truncationNote: String?

            package init(
                compare: String,
                detail: String?,
                files: [DiffFileDTO]?,
                totals: TotalsDTO,
                byStatus: [String: Int]?,
                oneliner: String,
                truncated: Bool?,
                truncationNote: String?
            ) {
                self.compare = compare
                self.detail = detail
                self.files = files
                self.totals = totals
                self.byStatus = byStatus
                self.oneliner = oneliner
                self.truncated = truncated
                self.truncationNote = truncationNote
            }

            private enum CodingKeys: String, CodingKey {
                case compare, detail, files, totals, oneliner, truncated
                case byStatus = "by_status"
                case truncationNote = "truncation_note"
            }
        }

        package struct DiffFileDTO: Codable, Equatable {
            package let path: String
            package let status: String
            package let insertions: Int?
            package let deletions: Int?
            package let hunks: [DiffHunkDTO]?

            package init(
                path: String,
                status: String,
                insertions: Int?,
                deletions: Int?,
                hunks: [DiffHunkDTO]?
            ) {
                self.path = path
                self.status = status
                self.insertions = insertions
                self.deletions = deletions
                self.hunks = hunks
            }

            private enum CodingKeys: String, CodingKey {
                case path, status, insertions, deletions, hunks
            }
        }

        package struct DiffHunkDTO: Codable, Equatable {
            package let header: String
            let oldStart: Int
            let newStart: Int
            package let patch: String

            package init(
                header: String,
                oldStart: Int,
                newStart: Int,
                patch: String
            ) {
                self.header = header
                self.oldStart = oldStart
                self.newStart = newStart
                self.patch = patch
            }

            private enum CodingKeys: String, CodingKey {
                case header, patch
                case oldStart = "old_start"
                case newStart = "new_start"
            }
        }

        package struct TotalsDTO: Codable, Equatable {
            package let files: Int
            package let insertions: Int
            package let deletions: Int

            package init(
                files: Int,
                insertions: Int,
                deletions: Int
            ) {
                self.files = files
                self.insertions = insertions
                self.deletions = deletions
            }
        }

        package struct LogDTO: Codable, Equatable {
            package let commits: [CommitSummaryDTO]

            package init(
                commits: [CommitSummaryDTO]
            ) {
                self.commits = commits
            }
        }

        package struct CommitSummaryDTO: Codable, Equatable {
            let sha: String
            package let shortSha: String
            package let author: String
            package let date: String
            package let message: String
            package let filesChanged: Int
            package let insertions: Int
            package let deletions: Int

            package init(
                sha: String,
                shortSha: String,
                author: String,
                date: String,
                message: String,
                filesChanged: Int,
                insertions: Int,
                deletions: Int
            ) {
                self.sha = sha
                self.shortSha = shortSha
                self.author = author
                self.date = date
                self.message = message
                self.filesChanged = filesChanged
                self.insertions = insertions
                self.deletions = deletions
            }

            private enum CodingKeys: String, CodingKey {
                case sha, author, date, message, insertions, deletions
                case shortSha = "short_sha"
                case filesChanged = "files_changed"
            }
        }

        package struct ShowDTO: Codable, Equatable {
            package let sha: String
            package let shortSha: String
            package let author: String
            package let date: String
            package let message: String
            package let files: [DiffFileDTO]?
            package let totals: TotalsDTO
            package let hunks: [DiffHunkDTO]?

            package init(
                sha: String,
                shortSha: String,
                author: String,
                date: String,
                message: String,
                files: [DiffFileDTO]?,
                totals: TotalsDTO,
                hunks: [DiffHunkDTO]?
            ) {
                self.sha = sha
                self.shortSha = shortSha
                self.author = author
                self.date = date
                self.message = message
                self.files = files
                self.totals = totals
                self.hunks = hunks
            }

            private enum CodingKeys: String, CodingKey {
                case sha, author, date, message, files, totals, hunks
                case shortSha = "short_sha"
            }
        }

        package struct BlameDTO: Codable, Equatable {
            package let path: String
            package let lines: [BlameLineDTO]

            package init(
                path: String,
                lines: [BlameLineDTO]
            ) {
                self.path = path
                self.lines = lines
            }
        }

        package struct BlameLineDTO: Codable, Equatable {
            package let num: Int
            package let sha: String
            package let author: String
            package let date: String
            package let content: String

            package init(
                num: Int,
                sha: String,
                author: String,
                date: String,
                content: String
            ) {
                self.num = num
                self.sha = sha
                self.author = author
                self.date = date
                self.content = content
            }
        }

        package struct SummaryDTO: Codable, Equatable {
            package let files: Int
            package let insertions: Int
            package let deletions: Int
            package let byStatus: [String: Int]?

            package init(
                files: Int,
                insertions: Int,
                deletions: Int,
                byStatus: [String: Int]?
            ) {
                self.files = files
                self.insertions = insertions
                self.deletions = deletions
                self.byStatus = byStatus
            }

            private enum CodingKeys: String, CodingKey {
                case files, insertions, deletions
                case byStatus = "by_status"
            }
        }

        package struct ArtifactsDTO: Codable, Equatable {
            let manifest: String
            package let map: String
            let filesTsv: String
            let changedLines: String?
            let tree: String
            let selectionPaths: String?
            package let allPatch: String?
            let deepHunks: String?
            let deepChangedLines: String?

            package init(
                manifest: String,
                map: String,
                filesTsv: String,
                changedLines: String?,
                tree: String,
                selectionPaths: String?,
                allPatch: String?,
                deepHunks: String?,
                deepChangedLines: String?
            ) {
                self.manifest = manifest
                self.map = map
                self.filesTsv = filesTsv
                self.changedLines = changedLines
                self.tree = tree
                self.selectionPaths = selectionPaths
                self.allPatch = allPatch
                self.deepHunks = deepHunks
                self.deepChangedLines = deepChangedLines
            }

            private enum CodingKeys: String, CodingKey {
                case manifest, map, tree
                case filesTsv = "files_tsv"
                case changedLines = "changed_lines"
                case selectionPaths = "selection_paths"
                case allPatch = "all_patch"
                case deepHunks = "deep_hunks"
                case deepChangedLines = "deep_changed_lines"
            }
        }

        package struct PrimaryArtifactsDTO: Codable, Equatable {
            package struct PerFilePatchDTO: Codable, Equatable {
                package let jumpIndex: Int
                package let gitPath: String
                package let selectionPath: String
                package let status: String?
                package let additions: Int?
                package let deletions: Int?

                package init(
                    jumpIndex: Int,
                    gitPath: String,
                    selectionPath: String,
                    status: String?,
                    additions: Int?,
                    deletions: Int?
                ) {
                    self.jumpIndex = jumpIndex
                    self.gitPath = gitPath
                    self.selectionPath = selectionPath
                    self.status = status
                    self.additions = additions
                    self.deletions = deletions
                }

                private enum CodingKeys: String, CodingKey {
                    case status, additions, deletions
                    case jumpIndex = "jump_index"
                    case gitPath = "git_path"
                    case selectionPath = "selection_path"
                }
            }

            package let map: String
            package let allPatch: String?
            package let autoSelected: [String]?
            package let perFilePatches: [PerFilePatchDTO]?

            package init(
                map: String,
                allPatch: String?,
                autoSelected: [String]?,
                perFilePatches: [PerFilePatchDTO]?
            ) {
                self.map = map
                self.allPatch = allPatch
                self.autoSelected = autoSelected
                self.perFilePatches = perFilePatches
            }

            private enum CodingKeys: String, CodingKey {
                case map
                case allPatch = "all_patch"
                case autoSelected = "auto_selected"
                case perFilePatches = "per_file_patches"
            }
        }

        package struct InlineDTO: Codable, Equatable {
            package let mapExcerpt: String
            package let truncated: Bool
            package let totalLines: Int
            package let returnedLines: Int

            package init(
                mapExcerpt: String,
                truncated: Bool,
                totalLines: Int,
                returnedLines: Int
            ) {
                self.mapExcerpt = mapExcerpt
                self.truncated = truncated
                self.totalLines = totalLines
                self.returnedLines = returnedLines
            }

            private enum CodingKeys: String, CodingKey {
                case mapExcerpt = "map_excerpt"
                case truncated
                case totalLines = "total_lines"
                case returnedLines = "returned_lines"
            }
        }

        package struct DiffInputsDTO: Codable, Equatable {
            package let compare: String
            let compareInput: String?
            package let scope: String
            let requestedPathsCount: Int?
            let contextLines: Int
            let detectRenames: Bool

            package init(
                compare: String,
                compareInput: String?,
                scope: String,
                requestedPathsCount: Int?,
                contextLines: Int,
                detectRenames: Bool
            ) {
                self.compare = compare
                self.compareInput = compareInput
                self.scope = scope
                self.requestedPathsCount = requestedPathsCount
                self.contextLines = contextLines
                self.detectRenames = detectRenames
            }

            private enum CodingKeys: String, CodingKey {
                case compare, scope
                case compareInput = "compare_input"
                case requestedPathsCount = "requested_paths_count"
                case contextLines = "context_lines"
                case detectRenames = "detect_renames"
            }
        }
    }

    // MARK: - Git Diff (legacy)

    struct GitDiffPublishReplyDTO: Codable, Equatable {
        let op: String
        let snapshotId: String?
        let snapshotDir: String?
        let artifacts: ArtifactsDTO?
        let summary: SummaryDTO?
        let oneliner: String?
        let inputs: InputsDTO?
        let modeDetails: String?
        let warning: String?
        let emptyReason: String?
        let inline: InlineDTO?
        let snapshots: [SnapshotEntryDTO]?
        let deleted: [String]?
        let notFound: [String]?

        struct ArtifactsDTO: Codable, Equatable {
            let manifest: String
            let map: String
            let filesTsv: String
            let changedLines: String?
            let tree: String
            let selectionPaths: String?
            let allPatch: String?
            let deepHunks: String?
            let deepChangedLines: String?

            private enum CodingKeys: String, CodingKey {
                case manifest
                case map
                case filesTsv = "files_tsv"
                case changedLines = "changed_lines"
                case tree
                case selectionPaths = "selection_paths"
                case allPatch = "all_patch"
                case deepHunks = "deep_hunks"
                case deepChangedLines = "deep_changed_lines"
            }
        }

        struct SummaryDTO: Codable, Equatable {
            let files: Int
            let insertions: Int
            let deletions: Int
            let byStatus: [String: Int]?

            private enum CodingKeys: String, CodingKey {
                case files
                case insertions
                case deletions
                case byStatus = "by_status"
            }
        }

        struct InputsDTO: Codable, Equatable {
            let compare: String
            let compareInput: String?
            let scope: String
            let requestedPathsCount: Int?
            let contextLines: Int
            let detectRenames: Bool

            private enum CodingKeys: String, CodingKey {
                case compare
                case compareInput = "compare_input"
                case scope
                case requestedPathsCount = "requested_paths_count"
                case contextLines = "context_lines"
                case detectRenames = "detect_renames"
            }
        }

        struct SnapshotEntryDTO: Codable, Equatable {
            let snapshotId: String
            let repoKey: String?
            let snapshotDir: String?
            let generatedAt: String
            let mode: String
            let compare: String
            let scope: String
            let summary: SummaryDTO
            let oneliner: String?
            let current: Bool?

            private enum CodingKeys: String, CodingKey {
                case snapshotId = "snapshot_id"
                case repoKey = "repo_key"
                case snapshotDir = "snapshot_dir"
                case generatedAt = "generated_at"
                case mode
                case compare
                case scope
                case summary
                case oneliner
                case current
            }
        }

        struct InlineDTO: Codable, Equatable {
            let mapExcerpt: String
            let truncated: Bool
            let totalLines: Int
            let returnedLines: Int

            private enum CodingKeys: String, CodingKey {
                case mapExcerpt = "map_excerpt"
                case truncated
                case totalLines = "total_lines"
                case returnedLines = "returned_lines"
            }
        }
    }

    /// Envelope for prompt tool results (discriminated by `op` field)
    package struct PromptToolEnvelope: Codable, Equatable {
        package let op: String
        package let prompt: PromptReply?
        package let export: PromptExportReply?
        package let presetsList: PresetsListReply?
        package let selectedPreset: CopyPresetDescriptorDTO?

        private enum CodingKeys: String, CodingKey {
            case op
            case prompt
            case export
            case presetsList = "presets_list"
            case selectedPreset = "selected_preset"
        }

        package static func forPrompt(_ reply: PromptReply, op: String) -> PromptToolEnvelope {
            PromptToolEnvelope(op: op, prompt: reply, export: nil, presetsList: nil, selectedPreset: nil)
        }

        package static func forExport(_ reply: PromptExportReply) -> PromptToolEnvelope {
            PromptToolEnvelope(op: "export", prompt: nil, export: reply, presetsList: nil, selectedPreset: nil)
        }

        package static func forPresetsList(_ presets: [CopyPresetListItemDTO]) -> PromptToolEnvelope {
            PromptToolEnvelope(op: "list_presets", prompt: nil, export: nil, presetsList: PresetsListReply(presets: presets), selectedPreset: nil)
        }

        package static func forSelectPreset(_ preset: CopyPresetDescriptorDTO) -> PromptToolEnvelope {
            PromptToolEnvelope(op: "select_preset", prompt: nil, export: nil, presetsList: nil, selectedPreset: preset)
        }
    }

    /// Unified prompt-context payload for `workspace_context`
    package struct PromptContextDTO: Codable, Equatable {
        package let prompt: String
        package let selection: SelectedFilesReply?
        /// When requested, raw content blocks (from selected files)
        package let fileBlocks: [String]?
        /// When requested (default), the codemap aggregation + unmapped files
        package let codeStructure: SelectedCodeStructureDTO?
        /// Optional selected file tree
        package let fileTree: FileTreeDTO?
        /// Optional token stats (normalized/agent view - always includes codemaps)
        package let tokenStats: TokenStats?
        /// Token stats matching user's copy preset settings (codemaps may be disabled)
        let userTokenStats: TokenStats?
        /// Explains why tokenStats and userTokenStats differ (e.g., codemap settings)
        let tokenStatsNote: String?
        /// Cache freshness and pending refresh state for token fields.
        package let tokenAccounting: TokenAccountingDTO?
        /// Active and effective copy preset information (when override is used)
        package let copyPreset: CopyPresetContextDTO?
        /// Available copy presets (when include contains "presets")
        package let copyPresets: [CopyPresetListItemDTO]?
        /// Active logical→effective worktree scope for filesystem-derived context.
        package let worktreeScope: WorktreeScopeDTO?

        package init(
            prompt: String,
            selection: SelectedFilesReply?,
            fileBlocks: [String]?,
            codeStructure: SelectedCodeStructureDTO?,
            fileTree: FileTreeDTO?,
            tokenStats: TokenStats?,
            userTokenStats: TokenStats?,
            tokenStatsNote: String?,
            tokenAccounting: TokenAccountingDTO? = nil,
            copyPreset: CopyPresetContextDTO?,
            copyPresets: [CopyPresetListItemDTO]?,
            worktreeScope: WorktreeScopeDTO? = nil
        ) {
            self.prompt = prompt
            self.selection = selection
            self.fileBlocks = fileBlocks
            self.codeStructure = codeStructure
            self.fileTree = fileTree
            self.tokenStats = tokenStats
            self.userTokenStats = userTokenStats
            self.tokenStatsNote = tokenStatsNote
            self.tokenAccounting = tokenAccounting
            self.copyPreset = copyPreset
            self.copyPresets = copyPresets
            self.worktreeScope = worktreeScope
        }

        private enum CodingKeys: String, CodingKey {
            case prompt
            case selection
            case fileBlocks = "file_blocks"
            case codeStructure = "code_structure"
            case fileTree = "file_tree"
            case tokenStats = "token_stats"
            case userTokenStats = "user_token_stats"
            case tokenStatsNote = "token_stats_note"
            case tokenAccounting = "token_accounting"
            case copyPreset = "copy_preset"
            case copyPresets = "copy_presets"
            case worktreeScope = "worktree_scope"
        }
    }
}
