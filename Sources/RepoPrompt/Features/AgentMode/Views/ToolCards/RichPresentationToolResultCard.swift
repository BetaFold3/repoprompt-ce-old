import RepoPromptAgentCore
import SwiftUI

/// Compact result card for a successful `present_rich` row whose reference is rendered by a
/// visible rich-presentation block, so the document is not duplicated. Errors, progress and
/// unrecognized results keep their ordinary cards.
struct RichPresentationToolResultCard: View {
    let item: AgentChatItem

    private var title: String? {
        item.toolResultJSON.flatMap(AgentRichPresentationResultNormalizer.reference(fromResultText:))?.title
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.and.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text(title.map { "Rich presentation: \($0)" } ?? "Rich presentation")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
