import Foundation
import MCP
import RepoPromptAgentCore

/// `mcp.structured_results`: whether a connection advertises `outputSchema` in `tools/list` and
/// returns `structuredContent` beside the unchanged text. Read once when a connection registers
/// its handlers, so a change applies to the next connection: once a connection has advertised an
/// `outputSchema`, it keeps returning `structuredContent` for its lifetime.
enum MCPStructuredResultsMode: String, CaseIterable {
    case off
    case on

    static let defaultMode: Self = .off
}

/// Hand-written output schemas for the exploration tools whose results are typed DTOs in
/// `ToolResultDTOs`. Each schema mirrors the DTO's coding keys: non-optional fields are
/// `required`, optional fields are listed but not required (they are omitted when nil), and
/// every object allows additional properties so a later DTO field never makes a result invalid.
/// `MCPStructuredOutputTests` checks parity by encoding fixture DTOs.
///
/// Every schema also lists the optional reserved `AgentDelegatedQuestionNoticeWire.resultKey`
/// property: runtime metadata carrying committed delegated-question notices, present only when a
/// notice was delivered with the result (owner decision 2026-10-17). It is not part of the tool's
/// data; a consumer that keeps only tool data (for example a later code-mode sink) must treat the
/// key as reserved and route its entries as notices rather than as DTO fields.
///
/// The legacy `git` tool intentionally has no schema; `git_review_snapshot` declares the diff
/// shape of the same `GitToolReplyDTO`.
enum MCPToolOutputSchemas {
    /// `ToolResultDTOs.ReadFileReply`.
    static let readFile: Value = object(
        required: ["content", "total_lines", "first_line", "last_line"],
        properties: [
            "content": string,
            "total_lines": integer,
            "first_line": integer,
            "last_line": integer,
            "message": string,
            "display_path": string,
            "worktree_scope": worktreeScope,
            "error": string,
            "error_code": string,
            "retryable": boolean,
            "retry_after_ms": integer,
            AgentDelegatedQuestionNoticeWire.resultKey: delegatedQuestionNotices
        ]
    )

    /// `ToolResultDTOs.SearchResultDTO`.
    static let fileSearch: Value = object(
        required: [
            "total_matches", "total_files", "content_matches", "path_matches", "limit_hit",
            "per_file_counts", "path_match_lines", "content_match_groups"
        ],
        properties: [
            "total_matches": integer,
            "total_files": integer,
            "matched_files": integer,
            "searched_files": integer,
            "content_matches": integer,
            "path_matches": integer,
            "limit_hit": boolean,
            "per_file_counts": array(perFileCount),
            "path_match_lines": array(string),
            "content_match_groups": array(contentMatchGroup),
            "size_limit_hit": boolean,
            "omitted_total": integer,
            "omitted_content_matches": integer,
            "omitted_path_matches": integer,
            "error": string,
            "error_code": string,
            "retryable": boolean,
            "retry_after_ms": integer,
            "suggestion": string,
            "warning": string,
            "per_file_totals": array(perFileCount),
            "worktree_scope": worktreeScope,
            AgentDelegatedQuestionNoticeWire.resultKey: delegatedQuestionNotices
        ]
    )

    /// `ToolResultDTOs.FileTreeDTO`.
    static let getFileTree: Value = object(
        required: ["roots_count", "uses_legend", "tree"],
        properties: [
            "roots_count": integer,
            "uses_legend": boolean,
            "tree": string,
            "note": string,
            "was_truncated": boolean,
            "worktree_scope": worktreeScope,
            AgentDelegatedQuestionNoticeWire.resultKey: delegatedQuestionNotices
        ]
    )

    /// `ToolResultDTOs.CodeStructureReplyDTO`.
    static let getCodeStructure: Value = object(
        required: ["status", "files", "summary", "issues"],
        properties: [
            "status": string,
            "files": array(object(
                required: ["path", "role", "depth", "reached_by", "content", "tokens"],
                properties: [
                    "path": string,
                    "role": string,
                    "depth": integer,
                    "reached_by": array(string),
                    "content": string,
                    "tokens": integer
                ]
            )),
            "summary": object(
                required: [
                    "requested_seeds", "resolved_seeds", "returned_seeds", "returned_related",
                    "returned_files", "codemap_content_tokens", "examined_edges"
                ],
                properties: [
                    "requested_seeds": integer,
                    "resolved_seeds": integer,
                    "returned_seeds": integer,
                    "returned_related": integer,
                    "returned_files": integer,
                    "codemap_content_tokens": integer,
                    "examined_edges": integer
                ]
            ),
            "issues": array(object(
                required: ["code", "phase", "retryable", "message"],
                properties: [
                    "code": string,
                    "phase": string,
                    "path": string,
                    "retryable": boolean,
                    "retry_after_ms": integer,
                    "attempted": integer,
                    "limit": integer,
                    "message": string,
                    "detail": string
                ]
            )),
            "retry": object(
                required: ["retryable"],
                properties: [
                    "retryable": boolean,
                    "retry_after_ms": integer
                ]
            ),
            "worktree_scope": worktreeScope,
            AgentDelegatedQuestionNoticeWire.resultKey: delegatedQuestionNotices
        ]
    )

    /// `ToolResultDTOs.GitToolReplyDTO` as `git_review_snapshot` returns it: always `op = diff`
    /// with artifacts, so the status, log, show, and blame payloads of the legacy `git` tool are
    /// not declared. Multi-root snapshots fill `repos` and `aggregate`; single-root snapshots
    /// fill the flat fields.
    static let gitReviewSnapshot: Value = {
        let diffPayload: [String: Value] = [
            "diff": gitDiff,
            "worktree": gitWorktree,
            "snapshot_id": string,
            "snapshot_dir": string,
            "artifacts": gitArtifacts,
            "primary_artifacts": gitPrimaryArtifacts,
            "summary": gitSummary,
            "oneliner": string,
            "inputs": gitDiffInputs,
            "mode_details": string,
            "inline": gitInline,
            "warning": string,
            "empty_reason": string,
            "error": string
        ]
        let repo = object(
            required: ["repo_root", "repo_key"],
            properties: diffPayload.merging([
                "repo_root": string,
                "repo_key": string,
                "repo_name": string
            ]) { current, _ in current }
        )
        return object(
            required: ["op"],
            properties: diffPayload.merging([
                "op": string,
                "repos": array(repo),
                "aggregate": object(
                    required: [],
                    properties: [
                        "totals": gitTotals,
                        "by_status": countsByKey,
                        "oneliner": string,
                        "repo_count": integer
                    ]
                ),
                AgentDelegatedQuestionNoticeWire.resultKey: delegatedQuestionNotices
            ]) { current, _ in current }
        )
    }()

    /// Tool name → schema for every tool that advertises one.
    static let schemasByToolName: [String: Value] = [
        MCPWindowToolName.readFile: readFile,
        MCPWindowToolName.search: fileSearch,
        MCPWindowToolName.getFileTree: getFileTree,
        MCPWindowToolName.getCodeStructure: getCodeStructure,
        MCPWindowToolName.gitReviewSnapshot: gitReviewSnapshot
    ]

    // MARK: - Shared fragments

    /// Reserved notice entries: `[AgentDelegatedQuestionNoticePayload.wireValue()]`. `text` is the
    /// same rendered block that is appended to the text content.
    static let delegatedQuestionNotices: Value = array(object(
        required: [
            "kind", "child_session_id", "child_session_name", "interaction_id", "guidance", "questions", "text"
        ],
        properties: [
            "kind": string,
            "child_session_id": string,
            "child_session_name": string,
            "interaction_id": string,
            "guidance": string,
            "questions": array(object(
                required: ["id", "question", "allows_multiple", "allows_custom", "options"],
                properties: [
                    "id": string,
                    "header": string,
                    "question": string,
                    "context": string,
                    "allows_multiple": boolean,
                    "allows_custom": boolean,
                    "options": array(object(
                        required: ["label"],
                        properties: ["label": string, "description": string]
                    ))
                ]
            )),
            "text": string,
            "title": string,
            "context": string
        ]
    ))

    /// `ToolResultDTOs.WorktreeScopeDTO`.
    private static let worktreeScope: Value = object(
        required: ["kind", "display_identity", "effective_identity", "root_mappings"],
        properties: [
            "kind": string,
            "display_identity": string,
            "effective_identity": string,
            "root_mappings": array(object(
                required: [
                    "logical_root_name", "logical_root_path", "effective_root_name",
                    "effective_root_path", "worktree_id"
                ],
                properties: [
                    "logical_root_name": string,
                    "logical_root_path": string,
                    "effective_root_name": string,
                    "effective_root_path": string,
                    "worktree_id": string,
                    "worktree_name": string,
                    "branch": string,
                    "label": string
                ]
            ))
        ]
    )

    /// `GitToolReplyDTO.TotalsDTO`.
    private static let gitTotals: Value = object(
        required: ["files", "insertions", "deletions"],
        properties: ["files": integer, "insertions": integer, "deletions": integer]
    )

    /// `GitToolReplyDTO.DiffDTO`.
    private static let gitDiff: Value = object(
        required: ["compare", "totals", "oneliner"],
        properties: [
            "compare": string,
            "detail": string,
            "files": array(object(
                required: ["path", "status"],
                properties: [
                    "path": string,
                    "status": string,
                    "insertions": integer,
                    "deletions": integer,
                    "hunks": array(object(
                        required: ["header", "old_start", "new_start", "patch"],
                        properties: [
                            "header": string,
                            "old_start": integer,
                            "new_start": integer,
                            "patch": string
                        ]
                    ))
                ]
            )),
            "totals": gitTotals,
            "by_status": countsByKey,
            "oneliner": string,
            "truncated": boolean,
            "truncation_note": string
        ]
    )

    /// `GitToolReplyDTO.WorktreeDTO`.
    private static let gitWorktree: Value = object(
        required: ["is_worktree", "worktree_root"],
        properties: [
            "is_worktree": boolean,
            "worktree_name": string,
            "worktree_root": string,
            "common_git_dir": string,
            "main_worktree_root": string,
            "worktree_branch": string,
            "main_branch": string,
            "worktree_head": string,
            "main_head": string
        ]
    )

    /// `GitToolReplyDTO.ArtifactsDTO`.
    private static let gitArtifacts: Value = object(
        required: ["manifest", "map", "files_tsv", "tree"],
        properties: [
            "manifest": string,
            "map": string,
            "files_tsv": string,
            "changed_lines": string,
            "tree": string,
            "selection_paths": string,
            "all_patch": string,
            "deep_hunks": string,
            "deep_changed_lines": string
        ]
    )

    /// `GitToolReplyDTO.PrimaryArtifactsDTO`.
    private static let gitPrimaryArtifacts: Value = object(
        required: ["map"],
        properties: [
            "map": string,
            "all_patch": string,
            "auto_selected": array(string),
            "per_file_patches": array(object(
                required: ["jump_index", "git_path", "selection_path"],
                properties: [
                    "jump_index": integer,
                    "git_path": string,
                    "selection_path": string,
                    "status": string,
                    "additions": integer,
                    "deletions": integer
                ]
            ))
        ]
    )

    /// `GitToolReplyDTO.SummaryDTO`.
    private static let gitSummary: Value = object(
        required: ["files", "insertions", "deletions"],
        properties: [
            "files": integer,
            "insertions": integer,
            "deletions": integer,
            "by_status": countsByKey
        ]
    )

    /// `GitToolReplyDTO.DiffInputsDTO`.
    private static let gitDiffInputs: Value = object(
        required: ["compare", "scope", "context_lines", "detect_renames"],
        properties: [
            "compare": string,
            "compare_input": string,
            "scope": string,
            "requested_paths_count": integer,
            "context_lines": integer,
            "detect_renames": boolean
        ]
    )

    /// `GitToolReplyDTO.InlineDTO`.
    private static let gitInline: Value = object(
        required: ["map_excerpt", "truncated", "total_lines", "returned_lines"],
        properties: [
            "map_excerpt": string,
            "truncated": boolean,
            "total_lines": integer,
            "returned_lines": integer
        ]
    )

    /// A `[String: Int]` map such as `by_status` (git status letter → file count).
    private static let countsByKey: Value = ["type": "object", "additionalProperties": integer]

    /// `ToolResultDTOs.PerFileCount`.
    private static let perFileCount: Value = object(
        required: ["path", "count"],
        properties: ["path": string, "count": integer]
    )

    /// `ToolResultDTOs.SearchResultDTO.ContentMatchGroup`.
    private static let contentMatchGroup: Value = {
        let contextLine = object(
            required: ["line_number", "line_text"],
            properties: ["line_number": integer, "line_text": string]
        )
        return object(
            required: ["path", "lines"],
            properties: [
                "path": string,
                "lines": array(object(
                    required: ["line_number", "line_text"],
                    properties: [
                        "line_number": integer,
                        "line_text": string,
                        "context_before": array(contextLine),
                        "context_after": array(contextLine)
                    ]
                ))
            ]
        )
    }()

    private static let string: Value = ["type": "string"]
    private static let integer: Value = ["type": "integer"]
    private static let boolean: Value = ["type": "boolean"]

    private static func array(_ items: Value) -> Value {
        ["type": "array", "items": items]
    }

    private static func object(required: [String], properties: [String: Value]) -> Value {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": true
        ]
    }
}
