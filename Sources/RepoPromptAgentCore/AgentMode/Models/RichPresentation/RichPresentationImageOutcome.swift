import Foundation

/// Bounds for optional article-image acquisition (rich presentation spec, A5). These are
/// configurable design limits that contain stalls and memory spikes, not measured SLAs.
/// App-wide download/decode concurrency belongs to the App's shared fetcher, not to these values.
package struct RichPresentationImageLimits: Equatable {
    /// Streamed, decompressed response bytes allowed for one image.
    package var maxImageBytes = 4 * 1024 * 1024
    /// Streamed, decompressed response bytes retained across all images of one artifact.
    package var maxArtifactBytes = 16 * 1024 * 1024
    /// Wall-clock bound for the whole image phase of one publication.
    package var imagePhaseDeadline: Duration = .seconds(20)
    /// Overflow-checked source pixel ceiling (`width × height`).
    package var maxSourcePixels = 24_000_000
    /// Longest edge of the normalized output.
    package var maxOutputLongestEdge = 1600
    /// Encoded size ceiling of the normalized JPEG.
    package var maxOutputBytes = 4 * 1024 * 1024

    package static let standard = RichPresentationImageLimits()

    package init() {}
}

/// A normalized local image recorded for one article. It never contains the request URL, its path
/// or its query; `origin` is the sanitized approved origin only.
package struct RichPresentationImageAsset: Equatable {
    /// Generated identifier; Step 3 names the stored JPEG after it.
    package let assetID: UUID
    package let width: Int
    package let height: Int
    package let alt: String
    package let credit: String?
    /// `https://<approved host>`: no userinfo, port, path, query or fragment.
    package let origin: String

    package init(assetID: UUID, width: Int, height: Int, alt: String, credit: String?, origin: String) {
        self.assetID = assetID
        self.width = width
        self.height = height
        self.alt = alt
        self.credit = credit
        self.origin = origin
    }

    /// The sanitized origin recorded for an image request URL, or `nil` when the URL is not an
    /// HTTPS URL with a valid exact host. Signed query bytes never survive into the origin.
    package static func sanitizedOrigin(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              case .success = RichPresentationURLPolicy.validateApprovedHost(host)
        else { return nil }
        return "https://\(host)"
    }
}

/// Terminal result of one image request: a local asset or a failure code. There is no pending or
/// retryable state; a failure shows a labeled placeholder while the article text remains.
package enum RichPresentationImageOutcome: Equatable {
    case asset(RichPresentationImageAsset)
    case failed(RichPresentationImageFailureCode)
}

/// The briefing article that requested an image, in document order.
package struct RichPresentationImageSlot: Equatable {
    package let sectionIndex: Int
    package let articleIndex: Int
    package let request: RichPresentationImageRequest

    package init(sectionIndex: Int, articleIndex: Int, request: RichPresentationImageRequest) {
        self.sectionIndex = sectionIndex
        self.articleIndex = articleIndex
        self.request = request
    }
}

package extension RichPresentationInput {
    /// Image requests of a validated input in section/article order; empty for charts.
    var imageSlots: [RichPresentationImageSlot] {
        guard case let .briefing(briefing) = content else { return [] }
        var slots: [RichPresentationImageSlot] = []
        for (sectionIndex, section) in briefing.sections.enumerated() {
            for (articleIndex, article) in section.articles.enumerated() {
                if let image = article.image {
                    slots.append(RichPresentationImageSlot(sectionIndex: sectionIndex, articleIndex: articleIndex, request: image))
                }
            }
        }
        return slots
    }
}

/// Stored terminal image outcome for one article (manifest value). Encodes flat, for example
/// `{"section_index":0,"article_index":1,"status":"failed","code":"deadline"}`; decoding is strict
/// (unknown fields, wrong types, out-of-range values and non-origin URLs are rejected).
package struct RichPresentationArticleImageOutcome: Codable, Equatable {
    package let sectionIndex: Int
    package let articleIndex: Int
    package let outcome: RichPresentationImageOutcome

    package init(sectionIndex: Int, articleIndex: Int, outcome: RichPresentationImageOutcome) {
        self.sectionIndex = sectionIndex
        self.articleIndex = articleIndex
        self.outcome = outcome
    }

    /// The reference warning for a failed image; `nil` for an asset.
    package var warning: RichPresentationWarning? {
        guard case let .failed(code) = outcome else { return nil }
        return RichPresentationWarning(sectionIndex: sectionIndex, articleIndex: articleIndex, code: code)
    }

    private enum CodingKeys: String, CodingKey {
        case sectionIndex = "section_index"
        case articleIndex = "article_index"
        case status
        case code
        case assetID = "asset_id"
        case width
        case height
        case alt
        case credit
        case origin
    }

    private static let assetStatus = "asset"
    private static let failedStatus = "failed"

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sectionIndex, forKey: .sectionIndex)
        try container.encode(articleIndex, forKey: .articleIndex)
        switch outcome {
        case let .asset(asset):
            try container.encode(Self.assetStatus, forKey: .status)
            try container.encode(asset.assetID, forKey: .assetID)
            try container.encode(asset.width, forKey: .width)
            try container.encode(asset.height, forKey: .height)
            try container.encode(asset.alt, forKey: .alt)
            try container.encodeIfPresent(asset.credit, forKey: .credit)
            try container.encode(asset.origin, forKey: .origin)
        case let .failed(code):
            try container.encode(Self.failedStatus, forKey: .status)
            try container.encode(code, forKey: .code)
        }
    }

    package init(from decoder: Decoder) throws {
        let node = try RichPresentationJSON(from: decoder)
        guard case let .object(object) = node else { throw Self.invalid("must be an object") }
        let sectionIndex = try Self.index(object["section_index"], below: RichPresentationLimits.sections.upperBound)
        let articleIndex = try Self.index(object["article_index"], below: RichPresentationLimits.articlesTotal.upperBound)
        guard case let .string(status) = object["status"] else { throw Self.invalid("status must be a string") }
        let outcome: RichPresentationImageOutcome
        switch status {
        case Self.failedStatus:
            try Self.rejectUnknownKeys(object, allowed: ["section_index", "article_index", "status", "code"])
            guard case let .string(codeText) = object["code"],
                  let code = RichPresentationImageFailureCode(rawValue: codeText)
            else { throw Self.invalid("code must be a known failure code") }
            outcome = .failed(code)
        case Self.assetStatus:
            try Self.rejectUnknownKeys(
                object,
                allowed: ["section_index", "article_index", "status", "asset_id", "width", "height", "alt", "credit", "origin"]
            )
            guard case let .string(idText) = object["asset_id"], let assetID = UUID(uuidString: idText) else {
                throw Self.invalid("asset_id must be a UUID")
            }
            let maxEdge = RichPresentationImageLimits.standard.maxOutputLongestEdge
            let width = try Self.index(object["width"], below: maxEdge + 1)
            let height = try Self.index(object["height"], below: maxEdge + 1)
            guard width > 0, height > 0 else { throw Self.invalid("dimensions must be positive") }
            let alt = try Self.text(object["alt"])
            let credit = try object["credit"].map { try Self.text($0) }
            guard case let .string(origin) = object["origin"],
                  origin.hasPrefix("https://"),
                  case .success = RichPresentationURLPolicy.validateApprovedHost(String(origin.dropFirst("https://".count)))
            else { throw Self.invalid("origin must be https://<exact host>") }
            outcome = .asset(RichPresentationImageAsset(
                assetID: assetID,
                width: width,
                height: height,
                alt: alt,
                credit: credit,
                origin: origin
            ))
        default:
            throw Self.invalid("status must be \"asset\" or \"failed\"")
        }
        self.init(sectionIndex: sectionIndex, articleIndex: articleIndex, outcome: outcome)
    }

    private static func invalid(_ message: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "image outcome \(message)"))
    }

    private static func rejectUnknownKeys(_ object: [String: RichPresentationJSON], allowed: Set<String>) throws {
        if let unknown = object.keys.filter({ !allowed.contains($0) }).min() {
            throw invalid("has unsupported field \(unknown)")
        }
    }

    private static func index(_ node: RichPresentationJSON?, below bound: Int) throws -> Int {
        guard case let .number(value) = node, value >= 0, value < Double(bound), value.rounded(.towardZero) == value else {
            throw invalid("integer field is missing or out of range")
        }
        return Int(value)
    }

    private static func text(_ node: RichPresentationJSON?) throws -> String {
        guard case let .string(value) = node, value.count <= RichPresentationLimits.maxAltOrCreditCharacters else {
            throw invalid("alt/credit must be a string of at most \(RichPresentationLimits.maxAltOrCreditCharacters) characters")
        }
        return value
    }
}
