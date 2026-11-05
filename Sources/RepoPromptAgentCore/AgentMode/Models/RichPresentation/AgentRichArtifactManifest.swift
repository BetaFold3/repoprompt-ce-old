import Foundation

package enum AgentRichArtifactError: Error, LocalizedError {
    case busy, storageMoved, invalidManifest, invalidHandoffCutoff, sourceUnavailable
    case unsafePath, missingArtifact(UUID), unreadableReferences
    /// D2: the workspace's resolved storage directory and its session-persistence directory
    /// differ (for example, a global custom storage location is set). Not retryable.
    case storageLocationUnsupported
    package var errorDescription: String? {
        switch self {
        case .busy: "Rich presentation is busy. Try again after the current publications finish."
        case .storageMoved: "Workspace storage changed during this operation. Nothing was kept from it; retry the operation."
        case .invalidManifest, .unsafePath: "Rich artifact is invalid. Restore or repair the artifact, then retry the handoff."
        case .invalidHandoffCutoff: "The handoff cutoff is no longer available. Select a current transcript row and retry."
        case .sourceUnavailable: "The handoff source session is not saved. Save or reload the source session, then retry. The source is unchanged."
        case let .missingArtifact(id): "Required artifact \(id) is unavailable. Restore or repair it, then retry the handoff. The source is unchanged."
        case .storageLocationUnsupported: "Rich presentations are not supported for this workspace because its storage location differs from where its agent sessions are saved, for example when a global custom storage location is set. Nothing was created or copied, and the source is unchanged. Retrying will not help while the locations differ."
        case .unreadableReferences: "This session has rich presentation references this version cannot read. They are preserved unchanged, but the handoff is refused so none is lost. Open the session in the version that wrote them. The source is unchanged."
        }
    }
}

package struct AgentRichArtifactProvenance: Codable, Equatable {
    package let runID: UUID
    package let attemptID: UUID
    package let sessionID: UUID
    package let toolInvocationID: UUID

    package init(runID: UUID, attemptID: UUID, sessionID: UUID, toolInvocationID: UUID) {
        self.runID = runID
        self.attemptID = attemptID
        self.sessionID = sessionID
        self.toolInvocationID = toolInvocationID
    }
}

/// A manifest is NOT the original tool input. Its validated document has no image requests.
/// Terminal image records retain only presentation metadata and normalized local assets.
package struct AgentRichArtifactManifest: Codable, Equatable {
    package struct Image: Codable, Equatable {
        package let terminal: RichPresentationArticleImageOutcome
        package let alt: String
        package let credit: String?
    }

    /// Bounded manifest size: the 256 KiB accepted input plus at most four image records and
    /// provenance, re-encoded without slash escaping.
    package static let maxEncodedBytes = 320 * 1024

    package static func encoded(_ manifest: AgentRichArtifactManifest) throws -> Data {
        let data = try encoder.encode(manifest)
        guard data.count <= maxEncodedBytes else { throw AgentRichArtifactError.invalidManifest }
        return data
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }

    package let version: Int
    package let artifactID: UUID
    package let document: RichPresentationInput
    package let images: [Image]
    package let provenance: AgentRichArtifactProvenance

    package init(
        artifactID: UUID, input: RichPresentationInput,
        outcomes: [RichPresentationArticleImageOutcome], provenance: AgentRichArtifactProvenance
    ) throws {
        guard input.imageSlots.count == outcomes.count else { throw AgentRichArtifactError.invalidManifest }
        version = 1
        self.artifactID = artifactID
        self.provenance = provenance
        images = try zip(input.imageSlots, outcomes).map { slot, outcome in
            guard slot.sectionIndex == outcome.sectionIndex, slot.articleIndex == outcome.articleIndex else {
                throw AgentRichArtifactError.invalidManifest
            }
            return Image(terminal: outcome, alt: slot.request.alt, credit: slot.request.credit)
        }
        switch input.content {
        case .chart:
            document = input
        case let .briefing(briefing):
            document = RichPresentationInput(title: input.title, content: .briefing(RichPresentationBriefing(
                date: briefing.date, deck: briefing.deck,
                sections: briefing.sections.map { section in
                    RichPresentationSection(heading: section.heading, articles: section.articles.map {
                        RichPresentationArticle(headline: $0.headline, body: $0.body, sources: $0.sources)
                    })
                }
            )))
        }
        try validate()
    }

    package func validate() throws {
        guard version == 1, document.imageSlots.isEmpty, images.count <= RichPresentationLimits.maxImageRequests else {
            throw AgentRichArtifactError.invalidManifest
        }
        _ = try RichPresentationValidator.validateInput(data: Self.encoder.encode(document))
        var slots = Set<String>()
        var assets = Set<UUID>()
        for image in images {
            // Round-trip through the strict terminal decoder, including origin/dimension bounds.
            _ = try JSONDecoder().decode(RichPresentationArticleImageOutcome.self, from: JSONEncoder().encode(image.terminal))
            guard case let .briefing(briefing) = document.content,
                  briefing.sections.indices.contains(image.terminal.sectionIndex),
                  briefing.sections[image.terminal.sectionIndex].articles.indices.contains(image.terminal.articleIndex),
                  slots.insert("\(image.terminal.sectionIndex):\(image.terminal.articleIndex)").inserted,
                  image.alt.count <= RichPresentationLimits.maxAltOrCreditCharacters,
                  (image.credit?.count ?? 0) <= RichPresentationLimits.maxAltOrCreditCharacters
            else { throw AgentRichArtifactError.invalidManifest }
            if case let .asset(asset) = image.terminal.outcome {
                guard assets.insert(asset.assetID).inserted, asset.alt == image.alt, asset.credit == image.credit else {
                    throw AgentRichArtifactError.invalidManifest
                }
            }
        }
    }

    package func validate(reference: RichPresentationReference) throws {
        try validate()
        guard reference.artifactID == artifactID, reference.kind == document.kind, reference.title == document.title else {
            throw AgentRichArtifactError.invalidManifest
        }
    }

    package var assetIDs: [UUID] {
        images.compactMap { if case let .asset(asset) = $0.terminal.outcome { asset.assetID } else { nil } }
    }
}
