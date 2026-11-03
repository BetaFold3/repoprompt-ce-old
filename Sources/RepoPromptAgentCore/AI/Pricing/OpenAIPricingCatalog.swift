import CryptoKit
import Foundation

// MARK: - Pricing semantics

/// The only pricing basis this component supports: OpenAI Standard (global) list prices in
/// USD per one million tokens. It is a comparison basis, never a reconstruction of an invoice,
/// subscription charge, actual service tier, regional uplift, or tool fee.
package enum OpenAIPricingBasis: String, Codable, Equatable {
    case standardGlobalListPriceUSDPerMillionTokens
}

/// USD-per-million-token rates for one context band.
///
/// `nil` means the official table lists no amount (a `-` cell). That is unknown or
/// non-applicable, never numeric zero; a listed `$0.00` or `Free` is a real zero.
// swiftformat:disable:next redundantSendable
package struct OpenAIPricingRates: Codable, Equatable, Sendable {
    package let input: Decimal?
    package let cachedInput: Decimal?
    package let cacheWrite: Decimal?
    package let output: Decimal?

    package init(
        input: Decimal?,
        cachedInput: Decimal?,
        cacheWrite: Decimal?,
        output: Decimal?
    ) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
    }

    var isEmpty: Bool {
        input == nil && cachedInput == nil && cacheWrite == nil && output == nil
    }

    private enum CodingKeys: String, CodingKey {
        case input, cachedInput, cacheWrite, output
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try Self.decodeRate(container, .input)
        cachedInput = try Self.decodeRate(container, .cachedInput)
        cacheWrite = try Self.decodeRate(container, .cacheWrite)
        output = try Self.decodeRate(container, .output)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try Self.encodeRate(input, &container, .input)
        try Self.encodeRate(cachedInput, &container, .cachedInput)
        try Self.encodeRate(cacheWrite, &container, .cacheWrite)
        try Self.encodeRate(output, &container, .output)
    }

    /// Rates persist as exact decimal strings so JSON number handling can never round them.
    private static func decodeRate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Decimal? {
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        guard let value = OpenAIPricingDecimal.parse(text), value >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Invalid pricing rate '\(text)'"
            )
        }
        return value
    }

    private static func encodeRate(
        _ value: Decimal?,
        _ container: inout KeyedEncodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws {
        guard let value else { return }
        try container.encode(OpenAIPricingDecimal.canonicalString(value), forKey: key)
    }
}

/// Exact decimal text handling shared by the parser, seed, and persistence.
enum OpenAIPricingDecimal {
    private static let locale = Locale(identifier: "en_US_POSIX")

    /// Parses a plain decimal such as `1.25` or `0.005`. Rejects signs, exponents, grouping, and currency symbols.
    static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              trimmed.first != ".",
              trimmed.last != ".",
              trimmed.count(where: { $0 == "." }) <= 1,
              let value = Decimal(string: trimmed, locale: locale)
        else {
            return nil
        }
        return value
    }

    static func canonicalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).description(withLocale: locale)
    }
}

// swiftformat:disable:next redundantSendable
package struct OpenAIPricingContextBand: Codable, Equatable, Sendable {
    package enum Kind: String, Codable, Equatable {
        /// The model lists one set of rates for every context length.
        case all
        /// Rates below the model's context threshold.
        case shortContext
        /// Rates at or above the model's context threshold.
        case longContext
    }

    package let kind: Kind
    package let rates: OpenAIPricingRates
}

/// Per-dimension lower/upper rate bounds across every eligible band, describing the spread of a
/// model's listed rates. Usage pricing does not use it (Codex intervals are priced as a point in
/// one band). A dimension is `nil` when any eligible band lacks it, so a missing rate never
/// collapses into the cheaper band.
// swiftformat:disable:next redundantSendable
package struct OpenAIPricingRateEnvelope: Equatable, Sendable {
    package let input: ClosedRange<Decimal>?
    package let cachedInput: ClosedRange<Decimal>?
    package let cacheWrite: ClosedRange<Decimal>?
    package let output: ClosedRange<Decimal>?

    static let unavailable = OpenAIPricingRateEnvelope(
        input: nil,
        cachedInput: nil,
        cacheWrite: nil,
        output: nil
    )
}

/// Normalized pricing for one exact model ID. Band distinctions are preserved rather than
/// flattened; the usage pricer chooses exactly one band per interval and names any assumption
/// it makes when the evidence does not prove the band.
// swiftformat:disable:next redundantSendable
package struct OpenAIModelPricing: Codable, Equatable, Sendable {
    let modelID: String
    /// Ordered short → long. Either `[.all]`, `[.shortContext]`, or `[.shortContext, .longContext]`.
    let bands: [OpenAIPricingContextBand]
    /// The official context qualifier (for example `272_000` from `(<272K context length)`).
    /// `nil` when the document states none, even if two bands are listed.
    package let contextThresholdTokens: Int?

    init(
        modelID: String,
        bands: [OpenAIPricingContextBand],
        contextThresholdTokens: Int? = nil
    ) {
        self.modelID = OpenAIPricingCatalog.normalizedModelID(modelID)
        self.bands = bands
        self.contextThresholdTokens = contextThresholdTokens
    }

    /// Rates usable as a point estimate without band attribution; non-nil only for a single `.all` band.
    package var flatRates: OpenAIPricingRates? {
        guard bands.count == 1, let band = bands.first, band.kind == .all else {
            return nil
        }
        return band.rates
    }

    /// The band the official threshold assigns to a request of `contextTokens` input tokens.
    ///
    /// Returns `nil` when the threshold cannot decide: two listed bands without an official
    /// threshold, or a request at or above a threshold whose long band is not listed. Callers that
    /// must still price (for example with an unstated threshold) apply their own stated assumption.
    package func band(forContextTokens contextTokens: Int) -> OpenAIPricingContextBand? {
        if let flat = bands.first, bands.count == 1, flat.kind == .all {
            return flat
        }
        guard let contextThresholdTokens else {
            return nil
        }
        let wanted: OpenAIPricingContextBand.Kind = contextTokens < contextThresholdTokens
            ? .shortContext
            : .longContext
        return bands.first { $0.kind == wanted }
    }

    /// Bounds across all eligible bands, available only when the band set is complete
    /// (`.all`, or both short and long). Descriptive only; never used to price usage.
    package var rateEnvelope: OpenAIPricingRateEnvelope {
        let kinds = Set(bands.map(\.kind))
        let complete = kinds == [.all] || kinds == [.shortContext, .longContext]
        guard complete, !bands.isEmpty else {
            return .unavailable
        }
        return OpenAIPricingRateEnvelope(
            input: Self.range(bands.map(\.rates.input)),
            cachedInput: Self.range(bands.map(\.rates.cachedInput)),
            cacheWrite: Self.range(bands.map(\.rates.cacheWrite)),
            output: Self.range(bands.map(\.rates.output))
        )
    }

    private static func range(_ values: [Decimal?]) -> ClosedRange<Decimal>? {
        var lower: Decimal?
        var upper: Decimal?
        for value in values {
            guard let value else { return nil }
            lower = lower.map { min($0, value) } ?? value
            upper = upper.map { max($0, value) } ?? value
        }
        guard let lower, let upper else { return nil }
        return lower ... upper
    }
}

/// An explicitly reviewed alias from a published alias name to an exact priced model ID.
/// Aliases are never inferred from model-family names or prose.
// swiftformat:disable:next redundantSendable
struct OpenAIPricingAlias: Codable, Equatable, Sendable {
    let alias: String
    let targetModelID: String

    init(alias: String, targetModelID: String) {
        self.alias = OpenAIPricingCatalog.normalizedModelID(alias)
        self.targetModelID = OpenAIPricingCatalog.normalizedModelID(targetModelID)
    }
}

// MARK: - Catalog

/// Immutable normalized OpenAI pricing data. Construction sorts models/aliases by ID and
/// derives a content hash so two catalogs with equal prices share one `pricingVersion`.
// swiftformat:disable:next redundantSendable
struct OpenAIPricingCatalog: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let basis: OpenAIPricingBasis
    /// Sorted by model ID; IDs are unique.
    let models: [OpenAIModelPricing]
    /// Sorted by alias; aliases are unique and never collide with an exact model ID.
    let aliases: [OpenAIPricingAlias]
    /// SHA-256 (hex) of the canonical content; independent of capture/validation times.
    let pricingVersion: String

    /// - Precondition: model IDs are unique and alias names neither repeat nor shadow a model ID.
    ///   The parser and the reviewed seed guarantee this before construction.
    init(models: [OpenAIModelPricing], aliases: [OpenAIPricingAlias]) {
        let sortedModels = models.sorted { $0.modelID < $1.modelID }
        let sortedAliases = aliases.sorted { $0.alias < $1.alias }
        let modelIDs = Set(sortedModels.map(\.modelID))
        precondition(modelIDs.count == sortedModels.count, "Duplicate OpenAI pricing model IDs")
        precondition(
            Set(sortedAliases.map(\.alias)).count == sortedAliases.count
                && sortedAliases.allSatisfy { !modelIDs.contains($0.alias) },
            "Duplicate or shadowing OpenAI pricing aliases"
        )
        schemaVersion = Self.schemaVersion
        basis = .standardGlobalListPriceUSDPerMillionTokens
        self.models = sortedModels
        self.aliases = sortedAliases
        pricingVersion = Self.contentHash(models: sortedModels, aliases: sortedAliases)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, basis, models, aliases, pricingVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported OpenAI pricing catalog schema \(version)"
            )
        }
        let basis = try container.decode(OpenAIPricingBasis.self, forKey: .basis)
        let models = try container.decode([OpenAIModelPricing].self, forKey: .models)
        let aliases = try container.decode([OpenAIPricingAlias].self, forKey: .aliases)
        let storedVersion = try container.decode(String.self, forKey: .pricingVersion)
        let modelIDs = Set(models.map(\.modelID))
        guard basis == .standardGlobalListPriceUSDPerMillionTokens,
              modelIDs.count == models.count,
              Set(aliases.map(\.alias)).count == aliases.count,
              aliases.allSatisfy({ !modelIDs.contains($0.alias) }),
              models.allSatisfy({ !$0.modelID.isEmpty && !$0.bands.isEmpty })
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .models,
                in: container,
                debugDescription: "Invalid OpenAI pricing catalog content"
            )
        }
        let rebuilt = OpenAIPricingCatalog(models: models, aliases: aliases)
        guard rebuilt.pricingVersion == storedVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .pricingVersion,
                in: container,
                debugDescription: "OpenAI pricing version does not match content"
            )
        }
        self = rebuilt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(basis, forKey: .basis)
        try container.encode(models, forKey: .models)
        try container.encode(aliases, forKey: .aliases)
        try container.encode(pricingVersion, forKey: .pricingVersion)
    }

    var isEmpty: Bool {
        models.isEmpty
    }

    func pricing(forExactModelID modelID: String) -> OpenAIModelPricing? {
        let normalized = Self.normalizedModelID(modelID)
        return models.first { $0.modelID == normalized }
    }

    /// Exact ID first, then an explicitly reviewed alias. An unlisted ID stays unpriced.
    func resolve(modelID: String) -> OpenAIModelPricingResolution? {
        let normalized = Self.normalizedModelID(modelID)
        guard !normalized.isEmpty else { return nil }
        if let exact = pricing(forExactModelID: normalized) {
            return OpenAIModelPricingResolution(
                requestedModelID: normalized,
                resolvedModelID: exact.modelID,
                matchedViaAlias: false,
                pricing: exact
            )
        }
        guard let alias = aliases.first(where: { $0.alias == normalized }),
              let target = pricing(forExactModelID: alias.targetModelID)
        else {
            return nil
        }
        return OpenAIModelPricingResolution(
            requestedModelID: normalized,
            resolvedModelID: target.modelID,
            matchedViaAlias: true,
            pricing: target
        )
    }

    static func normalizedModelID(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func contentHash(
        models: [OpenAIModelPricing],
        aliases: [OpenAIPricingAlias]
    ) -> String {
        var lines = ["openai-pricing-catalog/v\(schemaVersion)"]
        lines.append(OpenAIPricingBasis.standardGlobalListPriceUSDPerMillionTokens.rawValue)
        for model in models {
            var parts = ["model", model.modelID, model.contextThresholdTokens.map(String.init) ?? "-"]
            for band in model.bands {
                parts.append(band.kind.rawValue)
                for rate in [band.rates.input, band.rates.cachedInput, band.rates.cacheWrite, band.rates.output] {
                    parts.append(rate.map(OpenAIPricingDecimal.canonicalString) ?? "-")
                }
            }
            lines.append(parts.joined(separator: "\u{1F}"))
        }
        for alias in aliases {
            lines.append(["alias", alias.alias, alias.targetModelID].joined(separator: "\u{1F}"))
        }
        let digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// swiftformat:disable:next redundantSendable
package struct OpenAIModelPricingResolution: Equatable, Sendable {
    let requestedModelID: String
    package let resolvedModelID: String
    let matchedViaAlias: Bool
    package let pricing: OpenAIModelPricing
}

// MARK: - Snapshot and provider seam

package enum OpenAIPricingSourceKind: String, Codable, Equatable {
    /// The reviewed literal seed bundled with the app.
    case bundledSeed
    /// A previously fetched, validated catalog restored from local persistence.
    case persistedCache
    /// A catalog fetched and validated during this process lifetime.
    case fetched
}

/// Immutable, versioned pricing state captured at dispatch. A later refresh produces a new
/// snapshot and never mutates one already captured.
// swiftformat:disable:next redundantSendable
package struct OpenAIPricingSnapshot: Equatable, Sendable {
    let catalog: OpenAIPricingCatalog
    package let sourceKind: OpenAIPricingSourceKind
    /// Document date: `Last-Modified` for fetched content, the review date for the seed.
    package let capturedAt: Date
    /// Last successful validation (200 or valid 304); the review date for the seed.
    package let validatedAt: Date
    /// True when validation is older than the refresh interval at snapshot creation, or when
    /// the most recent refresh attempt after `validatedAt` failed.
    package let isStale: Bool

    package var pricingVersion: String {
        catalog.pricingVersion
    }

    package var basis: OpenAIPricingBasis {
        catalog.basis
    }

    package func rates(forModelID modelID: String) -> OpenAIModelPricingResolution? {
        catalog.resolve(modelID: modelID)
    }
}

/// Seam held by Codex dispatch. Methods are synchronous, nonisolated, and lock-guarded, so
/// they are safe from `@MainActor` and never wait on network or persistence.
package protocol OpenAIPricingProviding: AnyObject, Sendable {
    /// Immediate: seed, persisted last-good, or fetched catalog. Never blocks.
    func currentSnapshot() -> OpenAIPricingSnapshot
    /// Schedules at most one bounded background refresh when validation is due.
    /// Returns `true` when a refresh was scheduled by this call.
    @discardableResult
    func noteCodexDispatch() -> Bool
}
