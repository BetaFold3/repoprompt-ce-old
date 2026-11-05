import RepoPromptAgentCore
import SwiftUI

/// Briefing document (rich presentation spec, A6): masthead (title, date, deck) and ordered
/// sections of articles in eager native stacks, two columns when the block is at least 760 points
/// wide and one otherwise. No collapse, pagination, inner scrolling or lazy stack.
struct RichPresentationBriefingView: View {
    let title: String
    let briefing: RichPresentationBriefing
    let images: [AgentRichArtifactManifest.Image]
    let reference: RichPresentationReference
    let owner: RichPresentationHistoryLoader.Owner?
    let identity: RichPresentationHistoryLoader.LoadIdentity
    let loader: RichPresentationHistoryLoader

    static let twoColumnMinimumWidth: CGFloat = 760

    /// Column count for an available block width (two at 760 points and wider).
    static func columnCount(forWidth width: CGFloat) -> Int {
        width >= twoColumnMinimumWidth ? 2 : 1
    }

    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(briefing.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let deck = briefing.deck {
                    Text(deck)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            Divider()
            ForEach(Array(briefing.sections.enumerated()), id: \.offset) { sectionIndex, section in
                VStack(alignment: .leading, spacing: 10) {
                    Text(section.heading)
                        .font(.headline)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    articleRows(sectionIndex: sectionIndex, articles: section.articles)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: RichPresentationWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(RichPresentationWidthKey.self) { width = $0 }
    }

    @ViewBuilder
    private func articleRows(sectionIndex: Int, articles: [RichPresentationArticle]) -> some View {
        let columns = Self.columnCount(forWidth: width)
        let indexed = Array(articles.enumerated())
        let rows = stride(from: 0, to: indexed.count, by: columns).map { Array(indexed[$0 ..< min($0 + columns, indexed.count)]) }
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(row, id: \.offset) { articleIndex, article in
                        RichPresentationArticleView(
                            article: article,
                            image: images.first {
                                $0.terminal.sectionIndex == sectionIndex && $0.terminal.articleIndex == articleIndex
                            },
                            reference: reference,
                            owner: owner,
                            identity: identity,
                            loader: loader
                        )
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    if row.count < columns {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

private struct RichPresentationWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct RichPresentationArticleView: View {
    let article: RichPresentationArticle
    let image: AgentRichArtifactManifest.Image?
    let reference: RichPresentationReference
    let owner: RichPresentationHistoryLoader.Owner?
    let identity: RichPresentationHistoryLoader.LoadIdentity
    let loader: RichPresentationHistoryLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(article.headline)
                .font(.headline)
                .textSelection(.enabled)
            if let image {
                RichPresentationArticleImageView(
                    image: image, reference: reference, owner: owner, identity: identity, loader: loader
                )
            }
            Text(article.body)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            RichPresentationSourcesView(sources: article.sources)
        }
    }
}

/// A local asset (reserved at its recorded aspect ratio before decoding) or a labeled placeholder.
/// Like the block, the image task is keyed by the exact load identity plus the asset, and a
/// result is kept only for the identity it was read for.
struct RichPresentationArticleImageView: View {
    let image: AgentRichArtifactManifest.Image
    let reference: RichPresentationReference
    let owner: RichPresentationHistoryLoader.Owner?
    let identity: RichPresentationHistoryLoader.LoadIdentity
    let loader: RichPresentationHistoryLoader

    private struct Loaded {
        let identity: RichPresentationHistoryLoader.LoadIdentity
        let assetID: UUID
        let decoded: RichPresentationHistoryLoader.DecodedImage?
    }

    private struct TaskKey: Hashable {
        let identity: RichPresentationHistoryLoader.LoadIdentity
        let assetID: UUID
    }

    @State private var loaded: Loaded?

    var body: some View {
        switch image.terminal.outcome {
        case let .asset(asset):
            let current = loaded.flatMap { $0.identity == identity && $0.assetID == asset.assetID ? $0 : nil }
            VStack(alignment: .leading, spacing: 2) {
                Group {
                    if let decoded = current?.decoded {
                        Image(decoded.image, scale: 1, label: Text(image.alt))
                            .resizable()
                    } else {
                        placeholder(label: current != nil ? "Image unavailable" : nil)
                    }
                }
                .aspectRatio(CGFloat(max(asset.width, 1)) / CGFloat(max(asset.height, 1)), contentMode: .fit)
                .frame(maxWidth: .infinity)
                credit
            }
            .task(id: TaskKey(identity: identity, assetID: asset.assetID)) {
                let decoded = await loader.image(assetID: asset.assetID, reference: reference, owner: owner)
                guard !Task.isCancelled, loader.loadContext(for: reference, owner: owner) == .ready(identity) else { return }
                loaded = Loaded(identity: identity, assetID: asset.assetID, decoded: decoded)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 2) {
                placeholder(label: "Image unavailable")
                    .frame(height: 80)
                credit
            }
        }
    }

    @ViewBuilder
    private var credit: some View {
        if let credit = image.credit {
            Text(credit)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func placeholder(label: String?) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.08))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    if let label {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(image.alt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(6)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label.map { "\($0): \(image.alt)" } ?? image.alt)
    }
}
