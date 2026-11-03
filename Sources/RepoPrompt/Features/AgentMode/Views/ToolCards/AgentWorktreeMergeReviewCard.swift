import RepoPromptAgentCore
import RepoPromptUI
import RepoPromptWorkspace
import SwiftUI

// MARK: - Worktree Merge Review Card

//
// Pre-mutation review surface for `manage_worktree` merge ops. Mirrors the
// apply-edits review card pattern: shown in the Agent Mode blocker stack while
// a `PendingWorktreeMergeReview` is active, presents source/target endpoints,
// the merge graph/preflight summary, artifact paths, a bounded diff excerpt,
// and Merge/Cancel actions.
//
// SEARCH-HELPER: worktree merge approval card, merge review card,
// AgentWorktreeMergeReviewCard.
struct AgentWorktreeMergeReviewCard: View {
    let review: PendingWorktreeMergeReview
    let onAccept: () -> Void
    let onCancel: (_ reason: String) -> Void

    /// Optional resolver that lets the host (`AgentModeView`) load a bounded
    /// patch excerpt for the published diff artifact lazily. The card never
    /// loads patches by itself so view-model tests can pin the rendering input
    /// deterministically and the on-screen diff cannot block the main thread.
    var diffExcerptProvider: (() -> String?)?

    @State private var diffExcerpt: String? = nil
    @State private var didLoadDiffExcerpt = false

    private var summary: GitWorktreeMergeSummary? {
        review.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            endpointsRow

            if !review.visualization.isEmpty {
                visualizationBlock
            }

            preflightRow

            if let summary {
                summaryRow(summary)
            }

            if let artifacts = review.artifacts {
                artifactPathsBlock(artifacts)
            }

            diffExcerptBlock

            HStack {
                Button {
                    onCancel("Cancelled by user")
                } label: {
                    HStack(spacing: 4) {
                        Text("Cancel")
                        Text("⌘⌫")
                            .font(.caption2)
                            .opacity(0.6)
                    }
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.delete, modifiers: .command)
                .hoverTooltip("Cancel merge review (⌘⌫)")

                Spacer()

                Button(action: onAccept) {
                    HStack(spacing: 4) {
                        Text("Merge")
                        Text("⌘⏎")
                            .font(.caption2)
                            .opacity(0.6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .hoverTooltip("Apply merge (⌘⏎)")
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.purple.opacity(0.32), lineWidth: 1)
        )
        .onAppear(perform: loadDiffExcerptIfNeeded)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Worktree Merge Review")
                    .font(.headline)
                Text("Operation \(review.operationID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
    }

    // MARK: Endpoints

    private var endpointsRow: some View {
        HStack(spacing: 8) {
            mergeEndpointCapsule(
                role: "source",
                label: review.sourceLabel,
                branch: review.sourceBranch,
                head: review.sourceHead,
                path: review.sourcePath,
                tint: .blue
            )
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            mergeEndpointCapsule(
                role: "target",
                label: review.targetLabel,
                branch: review.targetBranch,
                head: review.targetHead,
                path: review.targetPath,
                tint: .orange
            )
        }
    }

    private func mergeEndpointCapsule(
        role: String,
        label: String,
        branch: String?,
        head: String,
        path: String,
        tint: Color
    ) -> some View {
        let shortHead = String(head.prefix(7))
        var pieces: [String] = [label]
        if let branch, !branch.isEmpty, branch != label {
            pieces.append(branch)
        }
        pieces.append(shortHead)
        let text = pieces.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 1) {
            Text(role.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(tint.opacity(0.10))
        )
        .overlay(
            Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 0.75)
        )
        .hoverTooltip(path, .top)
    }

    // MARK: Visualization

    private var visualizationBlock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(review.visualization)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
        }
        .frame(maxHeight: 100)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityLabel("Merge graph from \(review.sourceLabel) to \(review.targetLabel)")
    }

    // MARK: Preflight

    private var preflightRow: some View {
        let prediction = review.conflictPrediction
        let predictionBadge: (text: String, tint: Color) = switch prediction.status {
        case .clean: ("Predicted clean", .green)
        case .conflicts: (
                prediction.files.isEmpty
                    ? "Predicted conflicts"
                    : "Predicted conflicts (\(prediction.files.count))",
                .orange
            )
        case .unavailable: ("Prediction unavailable", .secondary)
        }

        return HStack(spacing: 6) {
            preflightBadge(text: predictionBadge.text, tint: predictionBadge.tint)

            if let message = prediction.message,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            preflightBadge(
                text: "merge-base \(String(review.mergeBase.prefix(7)))",
                tint: .secondary
            )
        }
    }

    private func preflightBadge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.10)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.75))
    }

    // MARK: Summary

    private func summaryRow(_ summary: GitWorktreeMergeSummary) -> some View {
        let parts = [
            "\(summary.commits) commit\(summary.commits == 1 ? "" : "s")",
            "\(summary.files) file\(summary.files == 1 ? "" : "s")",
            "+\(summary.insertions) -\(summary.deletions)"
        ]
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Artifacts

    private func artifactPathsBlock(_ artifacts: GitWorktreeMergePreviewArtifacts) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            artifactLine(label: "MAP", path: artifacts.mapPath)
            if let allPatch = artifacts.allPatchPath {
                artifactLine(label: "patch", path: allPatch)
            }
            artifactLine(label: "preview", path: artifacts.sidecarPath)
        }
    }

    private func artifactLine(label: String, path: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.8))
                .frame(width: 50, alignment: .leading)
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .hoverTooltip(path, .top)
    }

    // MARK: Diff excerpt

    @ViewBuilder
    private var diffExcerptBlock: some View {
        if let diff = diffExcerpt, !diff.isEmpty {
            UnifiedDiffView(diff: diff, largeBodyMaxHeight: 220)
        } else if review.artifacts?.allPatchPath != nil {
            Text("Diff excerpt unavailable. See artifact path above for full patch.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadDiffExcerptIfNeeded() {
        guard !didLoadDiffExcerpt else { return }
        didLoadDiffExcerpt = true
        guard let provider = diffExcerptProvider else { return }
        diffExcerpt = provider()
    }
}

// MARK: - Historical Worktree Merge Review Card (Step 5c)

//
// Read-only card for a preserved merge review whose request ended without being merged
// (lifecycle end, timeout, replacement, an unsaved rejection, an unstarted approval, or an app
// relaunch). It has no Merge action and never
// resumes the old request: View and Copy read the retained saved patch, Discard durably
// withdraws the review. The recorded conflict prediction is past proposal metadata; the "Now"
// line is a separate read-only fingerprint observation.
//
// SEARCH-HELPER: historical worktree merge review card, preserved merge proposal.
struct AgentWorktreeMergeHistoricalReviewCard: View {
    let operation: AgentSessionWorktreeMergeOperation
    let isDisabled: Bool
    let loadPastPrediction: () async -> GitWorktreeMergeConflictPrediction?
    let loadCurrentState: () async -> String
    let loadSavedPatch: () async -> WorktreeMergeSavedProposal
    let onCopy: () async -> String?
    /// Session-owned Discard state (survives this card being removed and recreated).
    let isDiscarding: Bool
    let discardMessage: String?
    /// Starts Discard; progress and any failure message come back through the session state.
    let onDiscard: () -> Void

    @State private var pastPrediction: GitWorktreeMergeConflictPrediction?
    @State private var currentState: String?
    @State private var savedPatch: WorktreeMergeSavedProposal?
    @State private var isShowingPatch = false
    @State private var copyMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ended Worktree Merge Review")
                        .font(.headline)
                    Text("\(operation.source.displayName) → \(operation.target.displayName) · operation \(operation.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            Text(endedText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = operation.summary {
                Text("\(summary.commits) commit\(summary.commits == 1 ? "" : "s") · \(summary.files) file\(summary.files == 1 ? "" : "s") · +\(summary.insertions) -\(summary.deletions)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(pastPredictionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(currentState ?? "Now: checking source and target…")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if isShowingPatch {
                savedPatchBlock
            }
            if let copyMessage {
                Text(copyMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let discardMessage {
                Text(discardMessage)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(isDiscarding ? "Discarding…" : "Discard") {
                    onDiscard()
                }
                .buttonStyle(.bordered)
                .disabled(isDiscarding)
                .hoverTooltip("Remove this ended review. Git is not changed.")
                Spacer()
                Button("Copy patch") {
                    Task { @MainActor in copyMessage = await onCopy() }
                }
                .buttonStyle(.bordered)
                .disabled(isDiscarding)
                Button(isShowingPatch ? "Hide patch" : "View patch") {
                    isShowingPatch.toggle()
                    guard isShowingPatch, savedPatch == nil else { return }
                    Task { @MainActor in savedPatch = await loadSavedPatch() }
                }
                .buttonStyle(.bordered)
                .disabled(isDiscarding)
            }
            .disabled(isDisabled)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .task(id: operation.id) {
            pastPrediction = await loadPastPrediction()
            currentState = await loadCurrentState()
        }
    }

    private var endedText: String {
        AgentModeViewModel.historicalWorktreeMergeReviewEndedText(reason: operation.reviewPreservation?.endedReason)
    }

    private var pastPredictionText: String {
        guard let pastPrediction else { return "When proposed: conflict prediction unavailable." }
        switch pastPrediction.status {
        case .clean:
            return "When proposed: predicted clean."
        case .conflicts:
            return pastPrediction.files.isEmpty
                ? "When proposed: predicted conflicts."
                : "When proposed: predicted conflicts (\(pastPrediction.files.count))."
        case .unavailable:
            return "When proposed: conflict prediction unavailable."
        }
    }

    @ViewBuilder
    private var savedPatchBlock: some View {
        switch savedPatch {
        case nil:
            Text("Loading saved patch…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .patch(text):
            UnifiedDiffView(diff: text, largeBodyMaxHeight: 220)
        case .noPatch:
            Text("This proposal has no saved patch content.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .unavailable(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
