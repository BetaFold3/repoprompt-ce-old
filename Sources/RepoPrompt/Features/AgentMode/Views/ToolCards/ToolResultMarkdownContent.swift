import AppKit
import Foundation
import Markdown
import MCP
import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

struct ToolMarkdownExpandedContent: View {
    let item: AgentChatItem
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var maxHeight: CGFloat {
        fontPreset.scaledClamped(200, max: 320)
    }

    private var presentation: ToolResultBodyPresentation? {
        ToolResultMarkdownRenderer.cachedPresentation(
            toolName: item.toolName,
            argsJSON: item.toolArgsJSON,
            resultPayload: item.toolResultJSON
        )
    }

    var body: some View {
        if let presentation {
            VStack(alignment: .leading, spacing: 4) {
                if let rawPayload = presentation.rawPayloadForCopy {
                    ToolStructuredResultRawCopyBar(
                        rawPayload: rawPayload,
                        fontPreset: fontPreset
                    )
                }
                ToolScrollableMarkdownTextView(
                    text: presentation.text,
                    maxHeight: maxHeight,
                    detectsMarkdownFilePaths: presentation.detectsMarkdownFilePaths
                )
            }
        } else {
            Text("No result")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

struct ToolScrollableMarkdownTextView: View {
    let text: String
    let maxHeight: CGFloat
    let detectsMarkdownFilePaths: Bool
    @Environment(\.markdownFileLinkOpener) private var markdownFileLinkOpener
    @ObservedObject private var fontScale = FontScaleManager.shared

    init(
        text: String,
        maxHeight: CGFloat,
        detectsMarkdownFilePaths: Bool = false
    ) {
        self.text = text
        self.maxHeight = maxHeight
        self.detectsMarkdownFilePaths = detectsMarkdownFilePaths
    }

    static func detectedFileLinks(
        in text: String,
        enabled: Bool
    ) -> [MarkdownFilePathLinkDetector.Match] {
        enabled ? ToolResultMarkdownLinkifier.matches(in: text) : []
    }

    @ObservedObject private var globalSettings = GlobalSettingsStore.shared

    /// Use the codeFont size (rawValue - 2) for a tighter fit in tool cards
    private var fontSize: Double {
        max(Double(fontScale.preset.rawValue) - 2, 9)
    }

    private var wrapLines: Bool {
        globalSettings.wrapTranscriptDiffLines()
    }

    var body: some View {
        TextKitView(
            text: .constant(text),
            isEditable: false,
            isSpellCheckEnabled: false,
            fontSize: fontSize,
            useMonospacedFont: true,
            useTranscriptCodeFont: true,
            preferredTranscriptCodeFontPostScriptName: globalSettings.transcriptCodeFontPostScriptName(),
            wrapLines: wrapLines,
            autohidesScrollers: true,
            scrollerStyle: .overlay,
            detectedMarkdownFileLinks: Self.detectedFileLinks(
                in: text,
                enabled: detectsMarkdownFilePaths
            ),
            markdownFileLinkOpener: markdownFileLinkOpener,
            contentFittingMaxHeight: maxHeight
        )
        // Live TextKit 1 wrap-geometry mutation can leave the view blank; the creation path is the
        // only reliable one, so this forces recreation. Removing it regresses the blank-card bug.
        .id(wrapLines)
        // `contentFittingMaxHeight` makes `TextKitView.sizeThatFits` report the measured height
        // (capped at `maxHeight`); fixing the vertical size keeps parents from stretching it.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Explicit access to the untouched stored payload when the body shows reserialized JSON.
private struct ToolStructuredResultRawCopyBar: View {
    let rawPayload: String
    let fontPreset: FontScalePreset

    var body: some View {
        HStack(spacing: 6) {
            Text("JSON")
                .font(fontPreset.swiftUIFont(sizeAtNormal: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rawPayload, forType: .string)
            } label: {
                Label("Copy raw", systemImage: "doc.on.doc")
                    .font(fontPreset.swiftUIFont(sizeAtNormal: 10))
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .hoverTooltip("Copy the original, unformatted tool result")
            .accessibilityLabel("Copy raw tool result")
        }
    }
}

private final class ToolResultMarkdownLinkMatchesBox: NSObject {
    let matches: [MarkdownFilePathLinkDetector.Match]

    init(_ matches: [MarkdownFilePathLinkDetector.Match]) {
        self.matches = matches
    }
}

enum ToolResultMarkdownLinkifier {
    private static let cache: NSCache<NSString, ToolResultMarkdownLinkMatchesBox> = {
        let cache = NSCache<NSString, ToolResultMarkdownLinkMatchesBox>()
        cache.countLimit = 16
        cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()

    static func matches(in source: String) -> [MarkdownFilePathLinkDetector.Match] {
        guard !source.isEmpty,
              MarkdownFilePathLinkDetector.containsSupportedExtension(in: source)
        else { return [] }

        let cacheKey = source as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached.matches
        }

        let document = Document(parsing: source, options: [.disableSmartOpts])
        let mapper = MarkdownSourceRangeMapper(source: source)
        let nsSource = source as NSString
        var result: [MarkdownFilePathLinkDetector.Match] = []
        collectMatches(
            from: document,
            mapper: mapper,
            source: nsSource,
            into: &result
        )
        let sorted = result.sorted { lhs, rhs in
            lhs.range.location < rhs.range.location
        }
        cache.setObject(
            ToolResultMarkdownLinkMatchesBox(sorted),
            forKey: cacheKey,
            cost: source.utf8.count
        )
        return sorted
    }

    private static func collectMatches(
        from markup: any Markup,
        mapper: MarkdownSourceRangeMapper,
        source: NSString,
        into result: inout [MarkdownFilePathLinkDetector.Match]
    ) {
        if markup is Markdown.CodeBlock || markup is Markdown.Link {
            return
        }

        if let inlineCode = markup as? Markdown.InlineCode {
            guard let match = MarkdownFilePathLinkDetector.inlineCodeMatch(in: inlineCode.code),
                  let sourceRange = inlineCode.range,
                  let mappedRange = mapper.nsRange(for: sourceRange)
            else { return }

            let pathRange = source.range(of: match.path, options: [], range: mappedRange)
            guard pathRange.location != NSNotFound else { return }
            result.append(.init(range: pathRange, path: match.path))
            return
        }

        if markup is Markdown.Text,
           let sourceRange = markup.range,
           let mappedRange = mapper.nsRange(for: sourceRange)
        {
            let text = source.substring(with: mappedRange)
            for match in MarkdownFilePathLinkDetector.proseMatches(in: text) {
                result.append(.init(
                    range: NSRange(
                        location: mappedRange.location + match.range.location,
                        length: match.range.length
                    ),
                    path: match.path
                ))
            }
            return
        }

        for child in markup.children {
            collectMatches(
                from: child,
                mapper: mapper,
                source: source,
                into: &result
            )
        }
    }
}

/// Typed expanded tool-result body. Canonical text is the verbatim Markdown-ish tool output and
/// opts into path detection; structured JSON is data, shown on the same TextKit surface with
/// path detection off (the same exclusion fenced code blocks already get).
struct ToolResultBodyPresentation: Equatable {
    enum Kind: Equatable {
        case canonicalText
        case structuredJSON
    }

    let text: String
    let kind: Kind
    /// The untouched stored payload, offered for a reserialization or `ToolJSON` extraction.
    /// Transport text bodies keep their authored text and do not offer a separate raw copy.
    let rawPayloadForCopy: String?

    var detectsMarkdownFilePaths: Bool {
        kind == .canonicalText
    }

    static func canonical(_ text: String) -> ToolResultBodyPresentation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ToolResultBodyPresentation(text: trimmed, kind: .canonicalText, rawPayloadForCopy: nil)
    }
}

private final class ToolResultBodyPresentationBox: NSObject {
    let presentation: ToolResultBodyPresentation?

    init(_ presentation: ToolResultBodyPresentation?) {
        self.presentation = presentation
    }
}

enum ToolResultMarkdownRenderer {
    private static let emitResourceContentKey = "mcp.emitResourceContent"
    private static let syntheticJSONFencePrefix = "```json\n"
    private static let syntheticJSONFenceSuffix = "\n```"

    /// Small bounded memo so SwiftUI body re-evaluation does not re-run tool formatters.
    private static let cache: NSCache<NSString, ToolResultBodyPresentationBox> = {
        let cache = NSCache<NSString, ToolResultBodyPresentationBox>()
        cache.countLimit = 32
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func cachedPresentation(
        toolName: String?,
        argsJSON: String?,
        resultPayload: String?
    ) -> ToolResultBodyPresentation? {
        guard let resultPayload, !resultPayload.isEmpty else { return nil }
        let emitResources = UserDefaults.standard.bool(forKey: emitResourceContentKey)
        let key = [
            emitResources ? "1" : "0",
            toolName ?? "",
            argsJSON ?? "",
            resultPayload
        ].joined(separator: "\u{0}") as NSString
        if let cached = cache.object(forKey: key) {
            return cached.presentation
        }
        let built = Self.presentation(
            toolName: toolName,
            argsJSON: argsJSON,
            resultPayload: resultPayload,
            emitResources: emitResources
        )
        cache.setObject(
            ToolResultBodyPresentationBox(built),
            forKey: key,
            cost: key.length * 2
        )
        return built
    }

    static func presentation(
        toolName: String?,
        argsJSON: String?,
        resultPayload: String?,
        emitResources: Bool
    ) -> ToolResultBodyPresentation? {
        guard let resultPayload else { return nil }
        let payload = resultPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }

        // MCP transport text (including provider-authored fences) stays canonical, except that a
        // body whose every text block is a JSON object/array is data: same text, no path detection.
        if let transportParts = mcpTransportTextParts(from: payload) {
            return transportPresentation(parts: transportParts)
        }

        let preferredPayload = ToolJSON.preferredStructuredResultJSON(from: payload) ?? payload
        guard looksLikeJSONObjectOrArray(preferredPayload),
              let value = Value.fromJSONString(preferredPayload)
        else {
            return .canonical(preferredPayload)
        }

        let args = argsJSON.flatMap(Value.objectFromJSONString) ?? [:]
        let normalizedToolName = normalizedToolCardName(toolName) ?? ""

        let blocks = ToolOutputFormatter.buildContentBlocks(
            toolName: normalizedToolName,
            args: args,
            result: value,
            emitResources: emitResources
        )

        let joinedText = extractText(from: blocks)
        if joinedText.isEmpty {
            // No formatter text: the body is the JSON object/array itself.
            return structured(preferredPayload, storedPayload: resultPayload, trimmedPayload: payload)
        }
        if let display = appGeneratedJSONDisplay(formattedText: joinedText, value: value) {
            return structured(display, storedPayload: resultPayload, trimmedPayload: payload)
        }
        return .canonical(joinedText)
    }

    /// Joined transport text blocks. Typed as structured JSON (text unchanged apart from the
    /// per-block trim) only when every block on its own parses as a JSON object or array; any
    /// prose, fenced, scalar, or malformed block keeps the whole body canonical.
    static func transportPresentation(parts: [String]) -> ToolResultBodyPresentation? {
        let trimmedParts = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let joined = trimmedParts.joined(separator: "\n\n")
        guard !trimmedParts.isEmpty, trimmedParts.allSatisfy(isJSONObjectOrArrayText) else {
            return .canonical(joined)
        }
        return ToolResultBodyPresentation(text: joined, kind: .structuredJSON, rawPayloadForCopy: nil)
    }

    private static func isJSONObjectOrArrayText(_ text: String) -> Bool {
        guard looksLikeJSONObjectOrArray(text),
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        return parsed is [String: Any] || parsed is [Any]
    }

    /// JSON text when `formattedText` is exactly what the app's generic JSON presentation
    /// (`formatGeneric`'s synthetic fence, or `_rawJSON` compact output) produces for `value`.
    /// Anything else, including specialized formatters and appended notices, returns nil.
    static func appGeneratedJSONDisplay(formattedText: String, value: Value) -> String? {
        let prefix = syntheticJSONFencePrefix
        let suffix = syntheticJSONFenceSuffix
        if formattedText.hasPrefix(prefix),
           formattedText.hasSuffix(suffix),
           formattedText.utf8.count > prefix.utf8.count + suffix.utf8.count,
           formattedText == extractText(from: ToolOutputFormatter.formatGeneric(value: value))
        {
            return String(formattedText.dropFirst(prefix.count).dropLast(suffix.count))
        }
        if let first = formattedText.first,
           first == "{" || first == "[",
           formattedText == ToolOutputFormatter.rawJSONString(value)
        {
            return formattedText
        }
        return nil
    }

    private static func structured(
        _ text: String,
        storedPayload: String,
        trimmedPayload: String
    ) -> ToolResultBodyPresentation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ToolResultBodyPresentation(
            text: trimmed,
            kind: .structuredJSON,
            rawPayloadForCopy: trimmed == trimmedPayload ? nil : storedPayload
        )
    }

    /// Top-level keys allowed on a bare MCP call result for it to count as transport text.
    private static let bareTransportResultKeys: Set<String> = ["content", "isError", "_meta"]
    /// Structured aliases `ToolJSON.preferredStructuredResultJSON` prefers over content text.
    /// A non-null sibling under the transport envelope keeps that existing extraction.
    private static let structuredSiblingKeys = [
        "structuredContent",
        "structured_content",
        "structuredResult",
        "structured_result",
        "toolResult",
        "tool_result"
    ]
    /// Content-block keys `ToolJSON` extracts as structured data.
    private static let structuredContentBlockKeys = ["json", "structuredContent", "structured_content"]

    /// Joined text blocks of an MCP transport result, read from the original JSON.
    ///
    /// This must not start from `ToolRawJSON.object`, which already unwraps the
    /// `Ok`/`Err` envelope and would hide it. Supported shapes are a `content` array inside an
    /// `Ok`/`ok`/`Err`/`err` envelope, or a bare call result whose keys are only
    /// `content`, `isError`, and `_meta`. Either shape is declined when it carries non-null
    /// structured data (a structured sibling or a structured content block), so the existing
    /// structured extraction keeps precedence. Explicit `null` values carry no data and are ignored.
    static func mcpTransportMarkdown(from payload: String) -> String? {
        mcpTransportTextParts(from: payload)?.joined(separator: "\n\n")
    }

    /// Non-empty, trimmed transport text blocks in order; see `mcpTransportMarkdown`.
    static func mcpTransportTextParts(from payload: String) -> [String]? {
        guard let data = ToolJSON.data(from: payload),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let envelope = (object["Ok"] as? [String: Any])
            ?? (object["ok"] as? [String: Any])
            ?? (object["Err"] as? [String: Any])
            ?? (object["err"] as? [String: Any])
            ?? (isBareTransportResult(object) ? object : nil)
        guard let envelope,
              let content = envelope["content"] as? [Any], !content.isEmpty,
              !hasNonNullValue(in: envelope, forAnyOf: structuredSiblingKeys),
              !content.contains(where: { element in
                  (element as? [String: Any]).map {
                      hasNonNullValue(in: $0, forAnyOf: structuredContentBlockKeys)
                  } ?? false
              })
        else { return nil }
        let textParts = content.compactMap { element -> String? in
            guard let block = element as? [String: Any] else { return nil }
            if let type = block["type"] as? String,
               type.lowercased() != "text"
            {
                return nil
            }
            return block["text"] as? String
        }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !textParts.isEmpty else { return nil }
        return textParts
    }

    /// Bare call result keys, ignoring structured aliases whose value is an explicit `null`.
    private static func isBareTransportResult(_ object: [String: Any]) -> Bool {
        object.allSatisfy { key, value in
            bareTransportResultKeys.contains(key)
                || (structuredSiblingKeys.contains(key) && value is NSNull)
        }
    }

    private static func hasNonNullValue(in object: [String: Any], forAnyOf keys: [String]) -> Bool {
        keys.contains { key in
            guard let value = object[key] else { return false }
            return !(value is NSNull)
        }
    }

    private static func looksLikeJSONObjectOrArray(_ payload: String) -> Bool {
        guard let first = payload.first, let last = payload.last else {
            return false
        }
        return (first == "{" && last == "}") || (first == "[" && last == "]")
    }

    private static func extractText(from blocks: [MCP.Tool.Content]) -> String {
        let textParts = blocks.compactMap { block -> String? in
            if case let .text(text: text, annotations: _, _meta: _) = block {
                return text
            }
            return nil
        }
        return textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
