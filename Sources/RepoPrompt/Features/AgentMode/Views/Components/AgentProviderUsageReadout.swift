import RepoPromptAgentCore
import RepoPromptUI
import SwiftUI

/// Provider usage readout (latest-request cache-hit share and accumulated estimated cost) for one Agent Mode session.
///
/// Renders `AgentProviderUsageSnapshot.Presentation` verbatim: the projection
/// owns scope, coverage and unavailable-reason wording, so both hosts (runtime sidebar card and the
/// context-pill popover) stay identical. It is deliberately separate from `AgentContextIndicator`;
/// billed-turn usage is never context occupancy and shares no denominator with it.
struct AgentProviderUsageReadout: View {
    let presentation: AgentProviderUsageSnapshot.Presentation
    /// When true, the expanded per-metric explanation is rendered inside the context popover.
    /// Compact hosts keep the same information in the tooltip and accessibility value.
    var showsVisibleNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            metricRow(label: presentation.cacheHitRatioLabel, value: presentation.cacheHitRatioValue)
            metricRow(label: presentation.costEstimateLabel, value: presentation.costEstimateValue)

            if showsVisibleNote, let expanded = presentation.expandedDetailText {
                Text(expanded)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showsVisibleNote, let note = presentation.noteText {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hoverTooltip(presentation.detailText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue("\(presentation.readoutText). \(presentation.detailText)")
    }

    /// One labelled value: small tertiary label, semibold rounded value on the same baseline.
    private func metricRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}
