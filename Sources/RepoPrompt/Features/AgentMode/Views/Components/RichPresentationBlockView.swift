import RepoPromptAgentCore
import SwiftUI

/// One turn-owned rich presentation as a full outer transcript block (rich presentation spec, A6).
/// Never collapsed, paginated, inner-scrolled or lazily stacked. All text is plain and selectable;
/// source links are validated HTTPS URLs from the local manifest, opened through the inherited
/// `openURL` handler. A missing manifest shows the title and labeled fallback with restore
/// guidance and an explicit retry; a missing image shows only that image's placeholder.
///
/// Loading is keyed by the loader's exact `LoadIdentity` (owner lifetime, stamp, actual root and
/// revision, artifact), never by the artifact alone: a storage move or an owner replacement
/// changes it, which discards the previous state and restarts loading. Root mutations publish
/// through the observed publication service; owner changes arrive as a new `owner`.
struct RichPresentationBlockView: View {
    let presentation: AgentTranscriptRichPresentation
    let owner: RichPresentationHistoryLoader.Owner?
    let loader: RichPresentationHistoryLoader

    @ObservedObject private var storageGeneration: RichPresentationPublicationService
    @State private var loadState = RichPresentationBlockLoadState()
    @State private var retryGeneration = 0

    init(
        presentation: AgentTranscriptRichPresentation,
        owner: RichPresentationHistoryLoader.Owner?,
        loader: RichPresentationHistoryLoader = .shared
    ) {
        self.presentation = presentation
        self.owner = owner
        self.loader = loader
        _storageGeneration = ObservedObject(wrappedValue: loader.publicationService)
    }

    private var reference: RichPresentationReference {
        presentation.reference
    }

    private struct TaskKey: Hashable {
        let context: RichPresentationHistoryLoader.LoadContext
        let retry: Int
    }

    var body: some View {
        let context = loader.loadContext(for: reference, owner: owner)
        VStack(alignment: .leading, spacing: 10) {
            switch (context, loadState.displayed(for: context, cached: loader.cachedManifest(for:))) {
            case let (.ready(identity), .loaded(manifest)?):
                RichPresentationDocumentView(
                    manifest: manifest, reference: reference, owner: owner, identity: identity, loader: loader
                )
            case let (.ready(identity), .unavailable?):
                RichPresentationFallbackView(reference: reference) {
                    loader.forgetUnavailable(for: identity)
                    loadState.reset()
                    retryGeneration += 1
                }
            case (_, .unavailable?):
                RichPresentationFallbackView(reference: reference)
            default:
                Text(reference.title)
                    .font(.headline)
                    .textSelection(.enabled)
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading rich presentation")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.08), lineWidth: 0.5)
        )
        .task(id: TaskKey(context: context, retry: retryGeneration)) {
            guard case let .ready(identity) = context else { return }
            let result = await loader.manifest(for: reference, owner: owner)
            loadState.accept(result, startedFor: identity, current: loader.loadContext(for: reference, owner: owner))
        }
    }
}

/// A block's manifest state, owned by the exact identity it was loaded for. A state loaded for
/// another identity is never shown, and a completion that started for an older identity is
/// dropped, so a mounted block never keeps a stale root's or another owner's result.
struct RichPresentationBlockLoadState {
    private(set) var identity: RichPresentationHistoryLoader.LoadIdentity?
    private(set) var state: RichPresentationHistoryLoader.ManifestState?

    /// What the block shows for `context`; nil shows loading.
    func displayed(
        for context: RichPresentationHistoryLoader.LoadContext,
        cached: (RichPresentationHistoryLoader.LoadIdentity) -> RichPresentationHistoryLoader.ManifestState?
    ) -> RichPresentationHistoryLoader.ManifestState? {
        switch context {
        case .unavailable:
            return .unavailable
        case .pending:
            return nil
        case let .ready(current):
            if identity == current, let state { return state }
            return cached(current)
        }
    }

    /// Records a load that started for `startedFor` only while that is still the current identity.
    @discardableResult
    mutating func accept(
        _ result: RichPresentationHistoryLoader.ManifestState?,
        startedFor: RichPresentationHistoryLoader.LoadIdentity,
        current: RichPresentationHistoryLoader.LoadContext
    ) -> Bool {
        guard let result, current == .ready(startedFor) else { return false }
        identity = startedFor
        state = result
        return true
    }

    mutating func reset() {
        identity = nil
        state = nil
    }
}

/// Title, the reference's labeled summary and restore/republish guidance. With `retry`, a button
/// reads the files again (after the user restores them) instead of waiting for a relaunch.
struct RichPresentationFallbackView: View {
    let reference: RichPresentationReference
    var retry: (() -> Void)?

    static let guidance =
        "The full presentation is not available here. Restore this session's rich presentation files, or ask the agent to present it again."

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reference.title)
                .font(.headline)
            Text(reference.fallbackText)
                .font(.body)
            Text(Self.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let retry {
                Button("Try Again", action: retry)
                    .controlSize(.small)
            }
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
    }
}

/// A loaded manifest's document.
struct RichPresentationDocumentView: View {
    let manifest: AgentRichArtifactManifest
    let reference: RichPresentationReference
    let owner: RichPresentationHistoryLoader.Owner?
    let identity: RichPresentationHistoryLoader.LoadIdentity
    let loader: RichPresentationHistoryLoader

    var body: some View {
        switch manifest.document.content {
        case let .chart(chart):
            RichPresentationChartBlock(
                title: manifest.document.title, chart: chart,
                content: loader.chartContent(for: chart, identity: identity), reference: reference
            )
        case let .briefing(briefing):
            RichPresentationBriefingView(
                title: manifest.document.title,
                briefing: briefing,
                images: manifest.images,
                reference: reference,
                owner: owner,
                identity: identity,
                loader: loader
            )
        }
    }
}

/// Chart document: title, the existing native chart (300-point plot, legend, unit, UTC axis,
/// accessible marks), a plain-text data description and source links. `content` is parsed once
/// per loaded manifest (`RichPresentationHistoryLoader.chartContent`), never per render.
struct RichPresentationChartBlock: View {
    let title: String
    let chart: RichPresentationChart
    let content: RichPresentationChartView.Content?
    let reference: RichPresentationReference

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            if let content {
                RichPresentationChartView(content: content, xLabel: chart.xLabel, unit: chart.unit)
                    .accessibilityLabel(Self.accessibilitySummary(title: title, chart: chart))
            } else {
                RichPresentationFallbackView(reference: reference)
            }
            Text(Self.dataDescription(chart))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            RichPresentationSourcesView(sources: chart.sources)
        }
    }

    static func chartContent(_ chart: RichPresentationChart) -> RichPresentationChartView.Content? {
        let series = chart.series.map { RichPresentationChartView.Series(name: $0.name, y: $0.y) }
        switch chart.chartType {
        case .bar:
            return .bar(x: chart.x, series: series)
        case .line:
            var dates: [Date] = []
            for value in chart.x {
                guard let date = parseRFC3339(value) else { return nil }
                dates.append(date)
            }
            return .line(x: dates, series: series)
        }
    }

    /// The validator's own RFC 3339 parser, so every accepted line chart plots.
    static func parseRFC3339(_ value: String) -> Date? {
        RichPresentationDateParser.instant(rfc3339: value)?.date
    }

    static func dataDescription(_ chart: RichPresentationChart) -> String {
        let names = chart.series.map(\.name).joined(separator: ", ")
        let axis = chart.chartType == .line ? "\(chart.xLabel) (UTC)" : chart.xLabel
        return "\(chart.chartType == .line ? "Line" : "Bar") chart of \(names) by \(axis), in \(chart.unit); \(chart.x.count) points."
    }

    static func accessibilitySummary(title: String, chart: RichPresentationChart) -> String {
        "\(title). \(dataDescription(chart))"
    }
}

/// Source labels; a validated HTTPS URL becomes a link through the inherited `openURL` handler.
struct RichPresentationSourcesView: View {
    let sources: [RichPresentationSource]

    var body: some View {
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                    if let url = Self.linkURL(source.url) {
                        Link(source.label, destination: url)
                            .font(.caption)
                    } else {
                        Text(source.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sources")
        }
    }

    /// Only an HTTPS URL with a host (already validated at creation) becomes a link.
    static func linkURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        return url
    }
}
