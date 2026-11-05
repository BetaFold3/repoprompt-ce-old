import Foundation
import JSONSchema
import MCP
import RepoPromptAgentCore

/// `present_rich` (docs/context/specs/2026-11-04-rich-presentation-spec.md, Step 4).
///
/// Registered in every window catalog, but policy-gated (`MCPPolicyGatedTools`): it is listed and
/// callable only for a local Agent Mode run attempt whose captured workspace policy grants it
/// (`AgentRichPresentationToolPolicy`). Execution re-derives that authority from trusted request
/// metadata (`RichPresentationMCPToolService`); arguments never choose the window, tab,
/// workspace, session or storage. The schema mirrors `RichPresentationValidator`, which remains
/// the authority and rejects anything this schema cannot express.
@MainActor
final class MCPRichPresentationToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .richPresentation

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
    }

    func buildTools() -> [Tool] {
        [presentRichTool()]
    }

    private typealias Limits = RichPresentationLimits

    private func presentRichTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.presentRich,
            freshnessPolicy: .none,
            description: """
            Show the user one rich presentation inline in this Agent Mode transcript: a native line/bar chart or a newspaper-style briefing. Use it when a chart or a structured briefing communicates results better than prose; keep explaining in ordinary text as well.

            Send one JSON object: `{"version": \(Limits.schemaVersion), "title": …, "content": {"kind": "chart" | "briefing", …}}`. All text is plain text (no Markdown or HTML is interpreted). Unknown fields, unsupported versions and limit violations are rejected with the failing field and a recovery hint; nothing is created and content is never silently truncated. Serialized input is at most \(Limits.maxSerializedInputBytes / 1024) KiB.

            - **chart**: `chart_type` `line` (x = strictly increasing RFC 3339 timestamps with an offset) or `bar` (x = unique category labels); \(Limits.xValues.lowerBound)–\(Limits.xValues.upperBound) x values; \(Limits.series.lowerBound)–\(Limits.series.upperBound) uniquely named series, each with exactly one finite number or null per x value and at least one number; `x_label`, `unit`, and \(Limits.sourcesPerItem.lowerBound)–\(Limits.sourcesPerItem.upperBound) sources.
            - **briefing**: `date` (YYYY-MM-DD), optional `deck`, \(Limits.sections.lowerBound)–\(Limits.sections.upperBound) sections with a heading and articles (\(Limits.articlesTotal.upperBound) articles total), each with `headline`, `body`, \(Limits.sourcesPerItem.lowerBound)–\(Limits.sourcesPerItem.upperBound) sources and an optional image `{url, alt, credit?}` (at most \(Limits.maxImageRequests) images). Images are fetched once, now, only from hosts the owner approved for this workspace; a failed image becomes a warning and the article text stays.
            - Source `url` must be https; omit it for local evidence rather than inventing a link.

            Returns `{"presentation": {version, artifact_id, kind, title, fallback_text, warnings}}`. The presentation is stored with this session and rendered from local storage; later turns see only its short text summary. Available only when rich presentation is enabled in this workspace's settings. Each call creates a new presentation and is never retried automatically: if a reply is lost or times out, check this transcript for the presentation before calling again rather than resending.
            """,
            // Durable artifact per call, never idempotent, and remote image fetches (open world).
            annotations: .repoPromptDurableCreationWithNetworkFetch,
            inputSchema: .object(
                description: "One rich presentation: version, title and a chart or briefing content object.",
                properties: [
                    "version": .integer(description: "Schema version; must be \(Limits.schemaVersion).", enum: [.int(Limits.schemaVersion)]),
                    "title": .string(description: "Presentation title (1–\(Limits.maxTitleCharacters) characters)."),
                    "content": contentSchema()
                ],
                required: ["version", "title", "content"]
            )
        ) { [dependencies] _, args in
            try await dependencies.executePresentRich(args)
        }
    }

    private func contentSchema() -> JSONSchema {
        .object(
            description: """
            `kind` selects the variant. chart: chart_type, x_label, unit, x, series, sources. briefing: date, deck?, sections. Fields of the other variant are rejected.
            """,
            properties: [
                "kind": .string(description: "Presentation variant.", enum: ["chart", "briefing"]),
                "chart_type": .string(description: "[chart] line or bar.", enum: ["line", "bar"]),
                "x_label": .string(description: "[chart] X-axis label (may be empty; at most \(Limits.maxLabelCharacters) characters)."),
                "unit": .string(description: "[chart] Value unit (may be empty; at most \(Limits.maxLabelCharacters) characters)."),
                "x": .array(
                    description: "[chart] line: strictly increasing RFC 3339 timestamps with an offset; bar: unique category labels.",
                    items: .string()
                ),
                "series": .array(
                    description: "[chart] \(Limits.series.lowerBound)–\(Limits.series.upperBound) uniquely named series.",
                    items: .object(
                        properties: [
                            "name": .string(description: "Series name (1–\(Limits.maxLabelCharacters) characters)."),
                            "y": .array(
                                description: "Exactly one finite number or null per x value; at least one number.",
                                items: .anyOf([.number(), .null])
                            )
                        ],
                        required: ["name", "y"]
                    )
                ),
                "sources": .array(description: "[chart] Evidence for the chart.", items: sourceSchema()),
                "date": .string(description: "[briefing] Calendar date, YYYY-MM-DD."),
                "deck": .string(description: "[briefing] Optional standfirst (at most \(Limits.maxDeckCharacters) characters)."),
                "sections": .array(
                    description: "[briefing] \(Limits.sections.lowerBound)–\(Limits.sections.upperBound) sections.",
                    items: .object(
                        properties: [
                            "heading": .string(description: "Section heading (1–\(Limits.maxLabelCharacters) characters)."),
                            "articles": .array(
                                description: "At least one article; at most \(Limits.articlesTotal.upperBound) across all sections.",
                                items: articleSchema()
                            )
                        ],
                        required: ["heading", "articles"]
                    )
                )
            ],
            required: ["kind"]
        )
    }

    private func articleSchema() -> JSONSchema {
        .object(
            properties: [
                "headline": .string(description: "Headline (1–\(Limits.maxTitleCharacters) characters)."),
                "body": .string(description: "Plain-text body (1–\(Limits.maxBodyCharacters) characters)."),
                "sources": .array(description: "Evidence for the article.", items: sourceSchema()),
                "image": .object(
                    description: "Optional image from an owner-approved host; at most \(Limits.maxImageRequests) per briefing.",
                    properties: [
                        "url": .string(description: "https image URL (at most \(Limits.maxURLCharacters) characters)."),
                        "alt": .string(description: "Alt text (at most \(Limits.maxAltOrCreditCharacters) characters)."),
                        "credit": .string(description: "Optional credit (at most \(Limits.maxAltOrCreditCharacters) characters).")
                    ],
                    required: ["url", "alt"]
                )
            ],
            required: ["headline", "body", "sources"]
        )
    }

    private func sourceSchema() -> JSONSchema {
        .object(
            properties: [
                "label": .string(description: "Source label (1–\(Limits.maxLabelCharacters) characters)."),
                "url": .string(description: "Optional https URL; omit for local evidence.")
            ],
            required: ["label"]
        )
    }
}
