import Foundation

/// Schema limits for `present_rich` version 1 (rich presentation spec, A2).
/// Excess is rejected with a field-specific error; accepted content is never truncated.
package enum RichPresentationLimits {
    package static let schemaVersion = 1
    package static let maxSerializedInputBytes = 256 * 1024
    package static let maxTitleCharacters = 160
    package static let maxLabelCharacters = 120
    package static let maxDeckCharacters = 1200
    package static let maxBodyCharacters = 12000
    package static let maxURLCharacters = 2048
    package static let maxAltOrCreditCharacters = 240
    package static let sourcesPerItem = 1 ... 4
    package static let sections = 1 ... 6
    package static let articlesTotal = 1 ... 12
    package static let maxImageRequests = 4
    package static let series = 1 ... 4
    package static let xValues = 1 ... 512
    package static let maxFallbackTextBytes = 2048
}

package enum RichPresentationKind: String, Codable, Equatable {
    case chart
    case briefing
}

package enum RichPresentationChartType: String, Codable, Equatable {
    case line
    case bar
}

/// Terminal image failure codes recorded per image request and surfaced as reference warnings.
package enum RichPresentationImageFailureCode: String, Codable, Equatable, CaseIterable, Error {
    case invalidURL = "invalid_url"
    case hostNotApproved = "host_not_approved"
    case redirectRejected = "redirect_rejected"
    case fetchFailed = "fetch_failed"
    case deadline
    case tooLarge = "too_large"
    case invalidImage = "invalid_image"
}

// MARK: - Input (all visible strings are plain text, stored exactly as supplied)

package struct RichPresentationSource: Encodable, Equatable {
    package let label: String
    /// Validated HTTPS URL text, preserved byte-for-byte; absent for local evidence.
    package let url: String?

    package init(label: String, url: String? = nil) {
        self.label = label
        self.url = url
    }
}

package struct RichPresentationImageRequest: Encodable, Equatable {
    /// Unvalidated beyond length: URL/host failures become per-image outcomes, not input errors.
    package let url: String
    package let alt: String
    package let credit: String?

    package init(url: String, alt: String, credit: String? = nil) {
        self.url = url
        self.alt = alt
        self.credit = credit
    }
}

package struct RichPresentationSeries: Encodable, Equatable {
    package let name: String
    /// Finite values; `nil` encodes as JSON `null` and breaks line charts.
    package let y: [Double?]

    package init(name: String, y: [Double?]) {
        self.name = name
        self.y = y
    }
}

package struct RichPresentationChart: Encodable, Equatable {
    package let chartType: RichPresentationChartType
    package let xLabel: String
    package let unit: String
    /// RFC 3339 timestamps for line charts (strictly increasing instants); unique categories for bar charts.
    package let x: [String]
    package let series: [RichPresentationSeries]
    package let sources: [RichPresentationSource]

    package init(
        chartType: RichPresentationChartType,
        xLabel: String,
        unit: String,
        x: [String],
        series: [RichPresentationSeries],
        sources: [RichPresentationSource]
    ) {
        self.chartType = chartType
        self.xLabel = xLabel
        self.unit = unit
        self.x = x
        self.series = series
        self.sources = sources
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case chartType = "chart_type"
        case xLabel = "x_label"
        case unit
        case x
        case series
        case sources
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(RichPresentationKind.chart, forKey: .kind)
        try container.encode(chartType, forKey: .chartType)
        try container.encode(xLabel, forKey: .xLabel)
        try container.encode(unit, forKey: .unit)
        try container.encode(x, forKey: .x)
        try container.encode(series, forKey: .series)
        try container.encode(sources, forKey: .sources)
    }
}

package struct RichPresentationArticle: Encodable, Equatable {
    package let headline: String
    package let body: String
    package let sources: [RichPresentationSource]
    package let image: RichPresentationImageRequest?

    package init(
        headline: String,
        body: String,
        sources: [RichPresentationSource],
        image: RichPresentationImageRequest? = nil
    ) {
        self.headline = headline
        self.body = body
        self.sources = sources
        self.image = image
    }
}

package struct RichPresentationSection: Encodable, Equatable {
    package let heading: String
    package let articles: [RichPresentationArticle]

    package init(heading: String, articles: [RichPresentationArticle]) {
        self.heading = heading
        self.articles = articles
    }
}

package struct RichPresentationBriefing: Encodable, Equatable {
    /// Valid calendar date `YYYY-MM-DD`.
    package let date: String
    package let deck: String?
    package let sections: [RichPresentationSection]

    package init(date: String, deck: String? = nil, sections: [RichPresentationSection]) {
        self.date = date
        self.deck = deck
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case date
        case deck
        case sections
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(RichPresentationKind.briefing, forKey: .kind)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(deck, forKey: .deck)
        try container.encode(sections, forKey: .sections)
    }
}

package enum RichPresentationContent: Encodable, Equatable {
    case chart(RichPresentationChart)
    case briefing(RichPresentationBriefing)

    package var kind: RichPresentationKind {
        switch self {
        case .chart: .chart
        case .briefing: .briefing
        }
    }

    package func encode(to encoder: Encoder) throws {
        switch self {
        case let .chart(chart): try chart.encode(to: encoder)
        case let .briefing(briefing): try briefing.encode(to: encoder)
        }
    }
}

/// Versioned `present_rich` input. Decoding always runs the strict validator; use
/// `RichPresentationValidator.validateInput(data:)` for raw tool arguments so the serialized size limit applies.
package struct RichPresentationInput: Codable, Equatable {
    package let version: Int
    package let title: String
    package let content: RichPresentationContent

    package init(title: String, content: RichPresentationContent) {
        version = RichPresentationLimits.schemaVersion
        self.title = title
        self.content = content
    }

    package var kind: RichPresentationKind {
        content.kind
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case title
        case content
    }

    package init(from decoder: Decoder) throws {
        let node = try RichPresentationJSON(from: decoder)
        self = try RichPresentationValidator.parseInput(node)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
    }
}

// MARK: - Reference / result

package struct RichPresentationWarning: Codable, Equatable {
    package let sectionIndex: Int
    package let articleIndex: Int
    package let code: RichPresentationImageFailureCode

    package init(sectionIndex: Int, articleIndex: Int, code: RichPresentationImageFailureCode) {
        self.sectionIndex = sectionIndex
        self.articleIndex = articleIndex
        self.code = code
    }

    private enum CodingKeys: String, CodingKey {
        case sectionIndex = "section_index"
        case articleIndex = "article_index"
        case code
    }

    package init(from decoder: Decoder) throws {
        let node = try RichPresentationJSON(from: decoder)
        self = try RichPresentationValidator.parseWarning(node, path: "warning")
    }
}

/// Small versioned reference returned through the text tool result and retained on transcript turns.
package struct RichPresentationReference: Codable, Equatable {
    package let version: Int
    package let artifactID: UUID
    package let kind: RichPresentationKind
    package let title: String
    /// Clearly labeled summary (at most 2 KiB UTF-8); not the full document.
    package let fallbackText: String
    package let warnings: [RichPresentationWarning]

    package init(
        artifactID: UUID,
        kind: RichPresentationKind,
        title: String,
        fallbackText: String,
        warnings: [RichPresentationWarning] = []
    ) {
        version = RichPresentationLimits.schemaVersion
        self.artifactID = artifactID
        self.kind = kind
        self.title = title
        self.fallbackText = fallbackText
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case artifactID = "artifact_id"
        case kind
        case title
        case fallbackText = "fallback_text"
        case warnings
    }

    package init(from decoder: Decoder) throws {
        let node = try RichPresentationJSON(from: decoder)
        self = try RichPresentationValidator.parseReference(node, path: "")
    }
}

/// Successful tool result body: `{"presentation": Reference}`.
package struct RichPresentationResult: Codable, Equatable {
    package let presentation: RichPresentationReference

    package init(presentation: RichPresentationReference) {
        self.presentation = presentation
    }

    package init(from decoder: Decoder) throws {
        let node = try RichPresentationJSON(from: decoder)
        self = try RichPresentationValidator.parseResult(node)
    }
}
