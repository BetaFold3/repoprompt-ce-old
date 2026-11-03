# Agent Mode transcript preview deep links

Scope: read when the task touches Agent Mode transcript links that open Markdown or HTML in the utility-panel Preview, including assistant or user path detection, tagged-file badges, tool-result path linkification, click-time resolution, and panel reveal.
Authority: Authoritative
Last-verified: 2026-11-02

## Durable architecture and invariants

- Transcript Preview routing is limited to the case-insensitive extensions `md`, `markdown`, `html`, and `htm`, kept in parity with `AgentSessionArtifactKind`. Other authored file links retain the normal external-file behavior.
- `MarkdownFilePathLinkDetector` is the shared, purely lexical detector. Detection is opt-in and default-off at rendering primitives so chat, Preview, Oracle, and unrelated TextKit surfaces do not inherit transcript policy.
- Assistant rendered Markdown enables detection in compiler visitors. Prose and whole-token inline code may be detected; descendants of authored links and fenced code blocks are excluded. The detection policy participates in render signatures, equality, and segmented-streaming reuse.
- Auto-detected targets carry `.markdownDetectedFileLink` provenance. They never enter fuzzy external fallback when exact transcript mapping fails; authored links may retain their established fallback.
- Click-time resolution flows through `AgentTranscriptPreviewLinkResolver`, using the live Agent Changes root inputs, checkout mapping, and `AgentChangesArtifactLinkResolver`. Composer `@` markers are removed before mapping; in multi-root workspaces, unique canonical root aliases such as `ripple/docs/report.md` select that logical root, while ambiguous aliases fail closed. No post-mapping existence stat is required; the Preview remains the load authority.
- A successful route updates Preview state before revealing the panel. Reveal uses the window-targeted, reveal-only `.showAgentUtilityPanel` notification; it must never toggle a visible panel closed. Superseded click tasks are cancelled and cannot show or reveal stale results.
- Tagged-file interactions use canonical attachment `relativePath` metadata rather than display names. User prose uses the reserved in-process `repoprompt-preview://transcript-file?path=...` bridge in both collapsed and expanded representations; it is not an OS-registered scheme.

## M5 tool-result contract

`ToolMarkdownExpandedContent` opts only its canonical expanded, verbatim monospaced tool-result body into path detection. `ToolResultMarkdownRenderer` types that body as `ToolResultBodyPresentation` (canonical text or structured JSON), and only canonical text opts in. `ToolResultMarkdownLinkifier` parses that body as Markdown and maps Markdown AST source ranges back to the original string:

- prose and inline-code `md`/`markdown`/`html`/`htm` paths are eligible;
- authored `Link` descendants and `CodeBlock` interiors, including fenced and indented blocks, are skipped;
- the original tool-result text is not re-rendered or rewritten;
- detected ranges are attributed by `TextKitView` and routed through `MarkdownFileLinkOpener` with auto-detected provenance.

Structured-JSON exception: a JSON object or array body that comes from the app's own generic JSON presentation is shown without its fence, on the same `TextKitView` surface, with path detection off. The output must be exactly the synthetic `json` fence from `ToolOutputFormatter.formatGeneric` or the `_rawJSON` compact output for that value; any appended notice or other change disqualifies it. A JSON object or array body that produces no formatter text counts too. This is the same exclusion a fenced code block already gets, so JSON string values such as `"docs/x.md"` stay unlinked. It doesn't add link provenance, routing, or Preview security behavior. MCP transport text stays canonical, with every text block kept and authored fences unchanged. Transport text is read from the original JSON, never from the already-unwrapped `ToolRawJSON.object`. It's either a `content` array inside an `Ok`/`ok`/`Err`/`err` envelope or a bare call result with only `content`, `isError`, and `_meta`. Either shape defers to the existing `ToolJSON` extraction, with a raw-payload copy, when it carries non-null structured data. That means a `structuredContent`, `structured_content`, `structuredResult`, `structured_result`, `toolResult`, or `tool_result` sibling, or a content block with `json`, `structuredContent`, or `structured_content`. Explicit `null` values for those keys carry no data and are ignored. Narrow transport exception: when every transport text block is, on its own, a valid JSON object or array, the body is typed as structured JSON. The text is kept exactly (per-block trim, blocks joined with a blank line), nothing is reserialized, no raw-copy row is added, and path detection is off. If any block is prose, fenced text, a JSON scalar, or malformed JSON, the whole body stays canonical, including blocks that mix prose and JSON. Specialized formatter output, non-JSON text, and malformed JSON also stay canonical, with interior text unchanged. Surrounding whitespace on the body and on each transport text block is trimmed. When the shown JSON is reserialized or extracted (`ToolJSON.preferredStructuredResultJSON` extracts content; it doesn't preserve the whole payload), the card offers a copy of the untouched stored payload. The stored payload itself isn't changed.

`TextKitView` remains default-off and attributes detected ranges only when a `MarkdownFileLinkOpener` is present. Bash-specific surfaces, unified diffs, compressed groups, header chips, and code-block contents do not opt in.

## Owning source seams

- Routing and reveal: `Sources/RepoPrompt/Features/AgentMode/Services/UtilityPanel/AgentTranscriptPreviewLinkResolver.swift`, `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeView.swift`, `Sources/RepoPrompt/Features/AgentMode/Views/AgentModeDetailWithSidebarView.swift`, and `Sources/RepoPrompt/App/Notifications/AppNotifications.swift`.
- Detection and rendered Markdown interaction: `Sources/RepoPromptUI/Markdown/MarkdownFilePathLinkDetector.swift`, `EnhancedMarkdownCompiler.swift`, `MarkdownTextView.swift`, `EnhancedMarkdownView.swift`, and `MarkdownFileLinkInteraction.swift`.
- User and badge surfaces: `Sources/RepoPrompt/Features/AgentMode/Views/AgentMessageBubble.swift` and `Sources/RepoPromptUI/Components/CollapsibleUserMessage.swift`.
- Tool results: `Sources/RepoPrompt/Features/AgentMode/Views/ToolCards/ToolResultMarkdownContent.swift` and `Sources/RepoPromptUI/TextField/TextKitView.swift`.

## Smallest validation routes

- Detection, compiler boundaries, and render-cache policy: `make dev-test FILTER=MarkdownFilePathLinkDetectorTests`, `make dev-test FILTER=EnhancedMarkdownCompilerFileLinkTests`, and `make dev-test FILTER=MarkdownRenderSignatureTests`.
- Resolution, fallback, cancellation, and reveal targeting: `make dev-test FILTER=AgentTranscriptPreviewLinkResolverTests` and `make dev-test FILTER=AgentUtilityPanelPresentationStoreTests`.
- Tagged files and user prose: `make dev-test FILTER=TaggedFilesBadgeInteractionTests`, `make dev-test FILTER=CollapsibleUserMessageLinkificationTests`, and `make dev-test FILTER=AgentPreviewLinkRouterTests`.
- Canonical tool-result detection and click provenance: `make dev-test FILTER=ToolResultMarkdownLinkifierTests`.
- Tool-result body typing, the structured-JSON exception, and raw-copy policy: `make dev-test FILTER=ToolResultBodyPresentationTests`.

## Explicit non-goals

Fenced-code-interior linkification, Bash-specific linkification, unified-diff linkification, compressed tool-group or header-chip linkification, line-number scrolling inside Preview, chat-mode or Preview-panel auto-linkification, OS scheme registration, persistence changes, and Preview security changes are out of scope.
