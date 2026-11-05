import Foundation

/// Ordering uses the canonical activity sequenceIndex (session-wide, never a surviving-array index).
package struct AgentTranscriptRichPresentation: Codable, Equatable {
    package let reference: RichPresentationReference
    package let activityID: UUID
    package let activityOrder: Int

    package init(reference: RichPresentationReference, activityID: UUID, activityOrder: Int) {
        self.reference = reference
        self.activityID = activityID
        self.activityOrder = activityOrder
    }
}
