import Foundation

/// Presentation-only identity for an external (non-RepoPrompt) MCP tool name such as
/// `mcp__busycal__delete_event`.
///
/// This type only formats card titles, compact labels, and icons. It never feeds routing keys
/// (`normalizedToolCardName`), provider ingestion, persistence, or status inference. Parsing uses
/// the raw tool name so dotted server names survive the lossy dotted-suffix card normalization.
///
/// Recognized grammar (conservative, not an external provider's authority):
/// - Optional repeated `functions.` wrapping, then a case-insensitive `mcp__` prefix.
/// - The server is everything before the first following `__`; the tool is the remainder.
/// - Server and tool must be non-empty, must not begin or end with `_` (ambiguous separator runs),
///   and may contain only letters, digits, `_`, `-`, and `.`.
/// - Servers that look like RepoPrompt (any server containing `repoprompt`) are never external, so
///   RepoPrompt names and lookalikes keep their existing presentation.
package struct ExternalMCPToolPresentation: Equatable {
    /// Single icon for every recognized external MCP tool.
    package static let iconName = "puzzlepiece.extension"
    /// Separator between the action and server in one-string labels.
    package static let compactSeparator = " · "

    /// Server segment exactly as authored.
    package let serverName: String
    /// Tool segment exactly as authored.
    package let toolName: String
    /// Readable server label, e.g. `BusyCal`.
    package let serverLabel: String
    /// Readable Title Case action, e.g. `Delete Event`.
    package let actionTitle: String

    /// One-string label with the action first, e.g. `Delete Event · BusyCal`.
    package var compactLabel: String {
        actionTitle + Self.compactSeparator + serverLabel
    }

    package init?(rawToolName: String?) {
        guard var name = rawToolName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        while Self.hasCaseInsensitivePrefix(name, Self.functionsPrefix) {
            name = String(name.dropFirst(Self.functionsPrefix.count))
        }
        guard Self.hasCaseInsensitivePrefix(name, Self.mcpPrefix) else { return nil }
        let remainder = name.dropFirst(Self.mcpPrefix.count)
        guard let separator = remainder.range(of: "__") else { return nil }
        let server = String(remainder[..<separator.lowerBound])
        let tool = String(remainder[separator.upperBound...])
        guard Self.isWellFormedSegment(server),
              Self.isWellFormedSegment(tool),
              !server.lowercased().contains("repoprompt")
        else { return nil }

        // Server names are often identifiers or domains (`docs.rs`), so dots stay inside a word.
        let serverWords = Self.words(in: server, separators: ["_", "-"])
        // Tool names use dots as namespace separators (`items.get`), so dots split words.
        let toolWords = Self.words(in: tool, separators: ["_", "-", "."])
        guard !serverWords.isEmpty, !toolWords.isEmpty else { return nil }

        serverName = server
        toolName = tool
        serverLabel = serverWords.map(Self.displayWord).joined(separator: " ")
        actionTitle = toolWords.map(Self.displayWord).joined(separator: " ")
    }

    // MARK: - Private

    private static let functionsPrefix = "functions."
    private static let mcpPrefix = "mcp__"

    private static let allowedSegmentCharacters: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "_-.")
        return set
    }()

    /// Closed set of known acronyms and exact brand aliases, keyed by lowercased word and matched
    /// case-insensitively (`Pr`, `PR`, `pr` → `PR`; `GITHUB` → `GitHub`). Words outside this set keep
    /// authored mixed or upper case verbatim; unknown all-lowercase words get simple capitalization.
    private static let wordAliases: [String: String] = [
        "mcp": "MCP", "api": "API", "apis": "APIs", "url": "URL", "urls": "URLs",
        "id": "ID", "ids": "IDs", "json": "JSON", "http": "HTTP", "https": "HTTPS",
        "ui": "UI", "sql": "SQL", "pr": "PR", "prs": "PRs", "ai": "AI", "cli": "CLI",
        "uuid": "UUID", "uuids": "UUIDs", "html": "HTML", "pdf": "PDF", "csv": "CSV", "sdk": "SDK",
        "busycal": "BusyCal", "github": "GitHub"
    ]

    private static func hasCaseInsensitivePrefix(_ value: String, _ prefix: String) -> Bool {
        value.count >= prefix.count && value.prefix(prefix.count).lowercased() == prefix
    }

    private static func isWellFormedSegment(_ segment: String) -> Bool {
        !segment.isEmpty
            && !segment.hasPrefix("_")
            && !segment.hasSuffix("_")
            && segment.unicodeScalars.allSatisfy { allowedSegmentCharacters.contains($0) }
    }

    private static func words(in segment: String, separators: Set<Character>) -> [String] {
        segment.split(whereSeparator: { separators.contains($0) }).map(String.init)
    }

    private static func displayWord(_ word: String) -> String {
        let lowered = word.lowercased()
        if let alias = wordAliases[lowered] { return alias }
        guard word == lowered, let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}

/// Header title plus optional small source label for generic tool cards.
package struct ToolCardHeaderPresentation: Equatable {
    package let title: String
    package let sourceLabel: String?

    package init(title: String, sourceLabel: String?) {
        self.title = title
        self.sourceLabel = sourceLabel
    }

    /// Generic call/result header. External MCP tools (recognized from the raw name only) show the
    /// action as the title and the server as the source label; every other tool keeps its existing
    /// display name with no source label.
    package static func generic(rawToolName: String?, normalizedToolName: String?) -> ToolCardHeaderPresentation {
        if let external = ExternalMCPToolPresentation(rawToolName: rawToolName) {
            return ToolCardHeaderPresentation(title: external.actionTitle, sourceLabel: external.serverLabel)
        }
        return ToolCardHeaderPresentation(
            title: toolDisplayNameIgnoringExternalMCP(for: normalizedToolName ?? rawToolName),
            sourceLabel: nil
        )
    }
}
