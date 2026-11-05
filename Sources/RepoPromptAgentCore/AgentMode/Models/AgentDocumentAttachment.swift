import Foundation

/// Kinds of user-attached documents whose original bytes are kept in app-managed storage.
///
/// PNG/JPEG and other images stay on the separate `AgentImageAttachment` channel; this enum never
/// classifies images.
public enum AgentDocumentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case pdf
    case html

    /// Classifies a source file by its filename extension (case-insensitive). `.htm` is accepted as
    /// HTML. Returns `nil` for every other extension, including images.
    public init?(pathExtension: String) {
        switch pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pdf":
            self = .pdf
        case "html", "htm":
            self = .html
        default:
            return nil
        }
    }

    /// The canonical extension used for the managed original (`.htm` sources are stored as `.html`).
    public var managedFileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .html: "html"
        }
    }

    /// Short user- and agent-visible type label.
    public var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .html: "HTML"
        }
    }

    public var mimeType: String {
        switch self {
        case .pdf: "application/pdf"
        case .html: "text/html"
        }
    }
}

/// An immutable reference to a document whose original bytes were imported into app-managed storage.
///
/// The record deliberately carries no filesystem path: the managed file location is derived only
/// from `id` and `kind` by `AgentDocumentAttachmentStore`, so a persisted or decoded record can never
/// grant authority over an arbitrary path. `originalFilename` is user-visible metadata only.
public struct AgentDocumentAttachment: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    public let kind: AgentDocumentKind
    /// The source file's last path component at import time, preserved verbatim (including Unicode).
    public let originalFilename: String
    /// Size in bytes of the managed original copy.
    public let byteCount: Int64
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: AgentDocumentKind,
        originalFilename: String,
        byteCount: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.originalFilename = originalFilename
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}
