import Foundation

/// Field-specific rejection with a correction the agent can apply. Content is never silently truncated.
package struct RichPresentationValidationError: Error, Equatable, CustomStringConvertible {
    package enum Code: String, Equatable {
        case invalidJSON = "invalid_json"
        case tooLarge = "too_large"
        case missingField = "missing_field"
        case unknownField = "unknown_field"
        case wrongType = "wrong_type"
        case unsupportedVersion = "unsupported_version"
        case empty
        case tooLong = "too_long"
        case tooFew = "too_few"
        case tooMany = "too_many"
        case duplicate
        case invalidValue = "invalid_value"
        case lengthMismatch = "length_mismatch"
        case notIncreasing = "not_increasing"
    }

    /// Dotted field path such as `content.series[1].y[3]`; `input` for the whole input.
    package let field: String
    package let code: Code
    package let message: String

    package var description: String {
        "\(field): \(message)"
    }
}

/// JSON tree that keeps exact JSON types so booleans, numbers and strings never coerce into each other.
/// Non-finite or out-of-range numbers fail to decode.
indirect enum RichPresentationJSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RichPresentationJSON])
    case object([String: RichPresentationJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RichPresentationJSON].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: RichPresentationJSON].self))
        }
    }

    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }
}

/// Strict schema validator for `present_rich` v1 input and its reference/result (spec A2).
/// Unsupported versions, unknown fields at any level, wrong types and limit excess are rejected before any download.
package enum RichPresentationValidator {
    private typealias Limits = RichPresentationLimits
    private typealias JSON = RichPresentationJSON
    private typealias Failure = RichPresentationValidationError

    // MARK: Entry points

    /// Validates raw serialized tool arguments, including the serialized-size limit.
    package static func validateInput(data: Data) throws -> RichPresentationInput {
        guard data.count <= Limits.maxSerializedInputBytes else {
            throw fail("", .tooLarge, "serialized input is \(data.count) bytes; at most \(Limits.maxSerializedInputBytes) bytes are allowed. Shorten text or split it into several presentations.")
        }
        return try parseInput(decodeJSON(data))
    }

    package static func decodeReference(data: Data) throws -> RichPresentationReference {
        try parseReference(decodeJSON(data), path: "")
    }

    package static func decodeResult(data: Data) throws -> RichPresentationResult {
        try parseResult(decodeJSON(data))
    }

    private static func decodeJSON(_ data: Data) throws -> JSON {
        do {
            return try JSONDecoder().decode(JSON.self, from: data)
        } catch {
            throw fail("", .invalidJSON, "is not valid JSON with finite numbers. Send one JSON object matching the schema.")
        }
    }

    // MARK: Input

    static func parseInput(_ node: RichPresentationJSON) throws -> RichPresentationInput {
        let object = try requireObject(node, path: "")
        try requireVersion(object, path: "")
        try rejectUnknownKeys(object, allowed: ["version", "title", "content"], path: "")
        let title = try text(required(object, "title", path: ""), path: "title", limit: Limits.maxTitleCharacters, nonEmpty: true)
        let content = try parseContent(required(object, "content", path: ""), path: "content")
        return RichPresentationInput(title: title, content: content)
    }

    private static func parseContent(_ node: JSON, path: String) throws -> RichPresentationContent {
        let object = try requireObject(node, path: path)
        let kindPath = field(path, "kind")
        let kindText = try string(required(object, "kind", path: path), path: kindPath)
        switch RichPresentationKind(rawValue: kindText) {
        case .chart: return try .chart(parseChart(object, path: path))
        case .briefing: return try .briefing(parseBriefing(object, path: path))
        case nil: throw fail(kindPath, .invalidValue, "must be \"chart\" or \"briefing\".")
        }
    }

    private static func parseChart(_ object: [String: JSON], path: String) throws -> RichPresentationChart {
        try rejectUnknownKeys(object, allowed: ["kind", "chart_type", "x_label", "unit", "x", "series", "sources"], path: path)
        let typePath = field(path, "chart_type")
        guard let chartType = try RichPresentationChartType(rawValue: string(required(object, "chart_type", path: path), path: typePath)) else {
            throw fail(typePath, .invalidValue, "must be \"line\" or \"bar\".")
        }
        let xLabel = try text(required(object, "x_label", path: path), path: field(path, "x_label"), limit: Limits.maxLabelCharacters, nonEmpty: false)
        let unit = try text(required(object, "unit", path: path), path: field(path, "unit"), limit: Limits.maxLabelCharacters, nonEmpty: false)

        let xPath = field(path, "x")
        let xNodes = try array(required(object, "x", path: path), path: xPath, count: Limits.xValues, noun: "values")
        let x = try xNodes.enumerated().map { index, node in
            try text(node, path: element(xPath, index), limit: Limits.maxLabelCharacters, nonEmpty: true)
        }
        switch chartType {
        case .line:
            var previous: RichPresentationInstant?
            for (index, value) in x.enumerated() {
                guard let instant = RichPresentationDateParser.instant(rfc3339: value) else {
                    throw fail(element(xPath, index), .invalidValue, "must be an RFC 3339 timestamp with a real date and a time-zone offset, such as 2026-11-05T14:30:00Z.")
                }
                if let previous, instant <= previous {
                    throw fail(element(xPath, index), .notIncreasing, "must be later than the previous timestamp; line x values must strictly increase by actual instant (offsets are compared in UTC).")
                }
                previous = instant
            }
        case .bar:
            var seen = Set<String>()
            for (index, value) in x.enumerated() where !seen.insert(value).inserted {
                throw fail(element(xPath, index), .duplicate, "repeats an earlier category; bar categories must be unique.")
            }
        }

        let seriesPath = field(path, "series")
        let seriesNodes = try array(required(object, "series", path: path), path: seriesPath, count: Limits.series, noun: "series")
        var names = Set<String>()
        var series: [RichPresentationSeries] = []
        for (index, node) in seriesNodes.enumerated() {
            let itemPath = element(seriesPath, index)
            let item = try requireObject(node, path: itemPath)
            try rejectUnknownKeys(item, allowed: ["name", "y"], path: itemPath)
            let namePath = field(itemPath, "name")
            let name = try text(required(item, "name", path: itemPath), path: namePath, limit: Limits.maxLabelCharacters, nonEmpty: true)
            guard names.insert(name).inserted else {
                throw fail(namePath, .duplicate, "repeats another series name; series names must be unique.")
            }
            let yPath = field(itemPath, "y")
            let yNode = try required(item, "y", path: itemPath)
            guard case let .array(yNodes) = yNode else {
                throw fail(yPath, .wrongType, "must be an array of numbers or null, not \(yNode.typeName).")
            }
            guard yNodes.count == x.count else {
                throw fail(yPath, .lengthMismatch, "has \(yNodes.count) values but x has \(x.count); provide exactly one number or null per x value.")
            }
            let y: [Double?] = try yNodes.enumerated().map { valueIndex, valueNode in
                switch valueNode {
                case .null:
                    return nil
                case let .number(value) where value.isFinite:
                    return value
                default:
                    throw fail(element(yPath, valueIndex), .wrongType, "must be a finite number or null, not \(valueNode.typeName).")
                }
            }
            guard y.contains(where: { $0 != nil }) else {
                throw fail(yPath, .invalidValue, "must contain at least one number; a series cannot be entirely null.")
            }
            series.append(RichPresentationSeries(name: name, y: y))
        }

        let sources = try parseSources(required(object, "sources", path: path), path: field(path, "sources"))
        return RichPresentationChart(chartType: chartType, xLabel: xLabel, unit: unit, x: x, series: series, sources: sources)
    }

    private static func parseBriefing(_ object: [String: JSON], path: String) throws -> RichPresentationBriefing {
        try rejectUnknownKeys(object, allowed: ["kind", "date", "deck", "sections"], path: path)
        let datePath = field(path, "date")
        let date = try string(required(object, "date", path: path), path: datePath)
        guard RichPresentationDateParser.isValidCalendarDate(date) else {
            throw fail(datePath, .invalidValue, "must be a real calendar date formatted YYYY-MM-DD.")
        }
        let deck = try optional(object, "deck", path: path).map {
            try text($0, path: field(path, "deck"), limit: Limits.maxDeckCharacters, nonEmpty: false)
        }

        let sectionsPath = field(path, "sections")
        let sectionNodes = try array(required(object, "sections", path: path), path: sectionsPath, count: Limits.sections, noun: "sections")
        var articleCount = 0
        var imageCount = 0
        var sections: [RichPresentationSection] = []
        for (sectionIndex, sectionNode) in sectionNodes.enumerated() {
            let sectionPath = element(sectionsPath, sectionIndex)
            let section = try requireObject(sectionNode, path: sectionPath)
            try rejectUnknownKeys(section, allowed: ["heading", "articles"], path: sectionPath)
            let heading = try text(required(section, "heading", path: sectionPath), path: field(sectionPath, "heading"), limit: Limits.maxLabelCharacters, nonEmpty: true)
            let articlesPath = field(sectionPath, "articles")
            let articleNodes = try array(required(section, "articles", path: sectionPath), path: articlesPath, count: 1 ... Limits.articlesTotal.upperBound, noun: "articles")
            var articles: [RichPresentationArticle] = []
            for (articleIndex, articleNode) in articleNodes.enumerated() {
                let articlePath = element(articlesPath, articleIndex)
                articleCount += 1
                guard articleCount <= Limits.articlesTotal.upperBound else {
                    throw fail(articlePath, .tooMany, "exceeds the limit of \(Limits.articlesTotal.upperBound) articles across all sections. Remove articles or publish another briefing.")
                }
                let article = try parseArticle(articleNode, path: articlePath)
                if article.image != nil {
                    imageCount += 1
                    guard imageCount <= Limits.maxImageRequests else {
                        throw fail(field(articlePath, "image"), .tooMany, "exceeds the limit of \(Limits.maxImageRequests) image requests per briefing. Remove this image; the article text can stay.")
                    }
                }
                articles.append(article)
            }
            sections.append(RichPresentationSection(heading: heading, articles: articles))
        }
        return RichPresentationBriefing(date: date, deck: deck, sections: sections)
    }

    private static func parseArticle(_ node: JSON, path: String) throws -> RichPresentationArticle {
        let object = try requireObject(node, path: path)
        try rejectUnknownKeys(object, allowed: ["headline", "body", "sources", "image"], path: path)
        let headline = try text(required(object, "headline", path: path), path: field(path, "headline"), limit: Limits.maxTitleCharacters, nonEmpty: true)
        let body = try text(required(object, "body", path: path), path: field(path, "body"), limit: Limits.maxBodyCharacters, nonEmpty: true)
        let sources = try parseSources(required(object, "sources", path: path), path: field(path, "sources"))
        let image = try optional(object, "image", path: path).map { try parseImage($0, path: field(path, "image")) }
        return RichPresentationArticle(headline: headline, body: body, sources: sources, image: image)
    }

    private static func parseImage(_ node: JSON, path: String) throws -> RichPresentationImageRequest {
        let object = try requireObject(node, path: path)
        try rejectUnknownKeys(object, allowed: ["url", "alt", "credit"], path: path)
        // URL syntax/host problems are per-image outcomes (invalid_url, host_not_approved), not input errors.
        let url = try text(required(object, "url", path: path), path: field(path, "url"), limit: Limits.maxURLCharacters, nonEmpty: false)
        let alt = try text(required(object, "alt", path: path), path: field(path, "alt"), limit: Limits.maxAltOrCreditCharacters, nonEmpty: false)
        let credit = try optional(object, "credit", path: path).map {
            try text($0, path: field(path, "credit"), limit: Limits.maxAltOrCreditCharacters, nonEmpty: false)
        }
        return RichPresentationImageRequest(url: url, alt: alt, credit: credit)
    }

    private static func parseSources(_ node: JSON, path: String) throws -> [RichPresentationSource] {
        let nodes = try array(node, path: path, count: Limits.sourcesPerItem, noun: "sources")
        return try nodes.enumerated().map { index, node in
            let itemPath = element(path, index)
            let object = try requireObject(node, path: itemPath)
            try rejectUnknownKeys(object, allowed: ["label", "url"], path: itemPath)
            let label = try text(required(object, "label", path: itemPath), path: field(itemPath, "label"), limit: Limits.maxLabelCharacters, nonEmpty: true)
            let urlPath = field(itemPath, "url")
            let url = try optional(object, "url", path: itemPath).map { urlNode in
                let value = try text(urlNode, path: urlPath, limit: Limits.maxURLCharacters, nonEmpty: false)
                guard RichPresentationURLPolicy.validatedSourceURL(value) != nil else {
                    throw fail(urlPath, .invalidValue, "must be an https:// URL with a host and no user name or password. Omit url for local evidence instead of inventing a link.")
                }
                return value
            }
            return RichPresentationSource(label: label, url: url)
        }
    }

    // MARK: Reference / result

    static func parseReference(_ node: RichPresentationJSON, path: String) throws -> RichPresentationReference {
        let object = try requireObject(node, path: path)
        try requireVersion(object, path: path)
        try rejectUnknownKeys(object, allowed: ["version", "artifact_id", "kind", "title", "fallback_text", "warnings"], path: path)
        let idPath = field(path, "artifact_id")
        guard let artifactID = try UUID(uuidString: string(required(object, "artifact_id", path: path), path: idPath)) else {
            throw fail(idPath, .invalidValue, "must be a UUID.")
        }
        let kindPath = field(path, "kind")
        guard let kind = try RichPresentationKind(rawValue: string(required(object, "kind", path: path), path: kindPath)) else {
            throw fail(kindPath, .invalidValue, "must be \"chart\" or \"briefing\".")
        }
        let title = try text(required(object, "title", path: path), path: field(path, "title"), limit: Limits.maxTitleCharacters, nonEmpty: true)
        let fallbackPath = field(path, "fallback_text")
        let fallbackText = try string(required(object, "fallback_text", path: path), path: fallbackPath)
        guard !fallbackText.allSatisfy(\.isWhitespace) else {
            throw fail(fallbackPath, .empty, "must contain visible text.")
        }
        guard fallbackText.utf8.count <= Limits.maxFallbackTextBytes else {
            throw fail(fallbackPath, .tooLong, "has \(fallbackText.utf8.count) UTF-8 bytes; at most \(Limits.maxFallbackTextBytes) are allowed.")
        }
        let warningsPath = field(path, "warnings")
        let warningNodes = try array(required(object, "warnings", path: path), path: warningsPath, count: 0 ... Limits.maxImageRequests, noun: "warnings")
        if kind == .chart, !warningNodes.isEmpty {
            throw fail(warningsPath, .invalidValue, "must be empty for charts; image warnings apply only to briefings.")
        }
        let warnings = try warningNodes.enumerated().map { index, node in
            try parseWarning(node, path: element(warningsPath, index))
        }
        return RichPresentationReference(artifactID: artifactID, kind: kind, title: title, fallbackText: fallbackText, warnings: warnings)
    }

    static func parseWarning(_ node: RichPresentationJSON, path: String) throws -> RichPresentationWarning {
        let object = try requireObject(node, path: path)
        try rejectUnknownKeys(object, allowed: ["section_index", "article_index", "code"], path: path)
        let sectionIndex = try index(required(object, "section_index", path: path), path: field(path, "section_index"), below: Limits.sections.upperBound)
        let articleIndex = try index(required(object, "article_index", path: path), path: field(path, "article_index"), below: Limits.articlesTotal.upperBound)
        let codePath = field(path, "code")
        guard let code = try RichPresentationImageFailureCode(rawValue: string(required(object, "code", path: path), path: codePath)) else {
            let allowed = RichPresentationImageFailureCode.allCases.map(\.rawValue).joined(separator: ", ")
            throw fail(codePath, .invalidValue, "must be one of \(allowed).")
        }
        return RichPresentationWarning(sectionIndex: sectionIndex, articleIndex: articleIndex, code: code)
    }

    static func parseResult(_ node: RichPresentationJSON) throws -> RichPresentationResult {
        let object = try requireObject(node, path: "")
        try rejectUnknownKeys(object, allowed: ["presentation"], path: "")
        return try RichPresentationResult(presentation: parseReference(required(object, "presentation", path: ""), path: "presentation"))
    }

    // MARK: Helpers

    private static func field(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }

    private static func element(_ path: String, _ index: Int) -> String {
        "\(path)[\(index)]"
    }

    private static func fail(_ path: String, _ code: Failure.Code, _ message: String) -> Failure {
        Failure(field: path.isEmpty ? "input" : path, code: code, message: message)
    }

    private static func requireObject(_ node: JSON, path: String) throws -> [String: JSON] {
        guard case let .object(object) = node else {
            throw fail(path, .wrongType, "must be an object, not \(node.typeName).")
        }
        return object
    }

    private static func requireVersion(_ object: [String: JSON], path: String) throws {
        let versionPath = field(path, "version")
        let node = try required(object, "version", path: path)
        guard case let .number(value) = node else {
            throw fail(versionPath, .wrongType, "must be the number \(Limits.schemaVersion), not \(node.typeName).")
        }
        guard value == Double(Limits.schemaVersion) else {
            throw fail(versionPath, .unsupportedVersion, "is not supported; use version \(Limits.schemaVersion).")
        }
    }

    private static func rejectUnknownKeys(_ object: [String: JSON], allowed: Set<String>, path: String) throws {
        guard let unknown = object.keys.filter({ !allowed.contains($0) }).min() else { return }
        throw fail(field(path, unknown), .unknownField, "is not a supported field. Remove it; allowed fields are \(allowed.sorted().joined(separator: ", ")).")
    }

    private static func required(_ object: [String: JSON], _ key: String, path: String) throws -> JSON {
        guard let value = object[key] else {
            throw fail(field(path, key), .missingField, "is required.")
        }
        return value
    }

    /// Optional fields must be omitted when absent; explicit `null` is rejected.
    private static func optional(_ object: [String: JSON], _ key: String, path: String) throws -> JSON? {
        guard let value = object[key] else { return nil }
        if case .null = value {
            throw fail(field(path, key), .wrongType, "must be omitted rather than null.")
        }
        return value
    }

    private static func string(_ node: JSON, path: String) throws -> String {
        guard case let .string(value) = node else {
            throw fail(path, .wrongType, "must be a string, not \(node.typeName).")
        }
        return value
    }

    /// Plain text returned exactly as supplied (no trimming or markup interpretation).
    private static func text(_ node: JSON, path: String, limit: Int, nonEmpty: Bool) throws -> String {
        let value = try string(node, path: path)
        if nonEmpty, value.allSatisfy(\.isWhitespace) {
            throw fail(path, .empty, "must contain visible text.")
        }
        let count = value.count
        guard count <= limit else {
            throw fail(path, .tooLong, "has \(count) characters; at most \(limit) are allowed. Shorten it; accepted content is never truncated.")
        }
        return value
    }

    private static func array(_ node: JSON, path: String, count range: ClosedRange<Int>, noun: String) throws -> [JSON] {
        guard case let .array(items) = node else {
            throw fail(path, .wrongType, "must be an array, not \(node.typeName).")
        }
        guard items.count >= range.lowerBound else {
            throw fail(path, .tooFew, "has \(items.count) \(noun); at least \(range.lowerBound) required.")
        }
        guard items.count <= range.upperBound else {
            throw fail(path, .tooMany, "has \(items.count) \(noun); at most \(range.upperBound) are allowed. Remove items or split into another presentation.")
        }
        return items
    }

    private static func index(_ node: JSON, path: String, below bound: Int) throws -> Int {
        guard case let .number(value) = node else {
            throw fail(path, .wrongType, "must be an integer, not \(node.typeName).")
        }
        guard value >= 0, value < Double(bound), value.rounded(.towardZero) == value else {
            throw fail(path, .invalidValue, "must be an integer from 0 to \(bound - 1).")
        }
        return Int(value)
    }
}
