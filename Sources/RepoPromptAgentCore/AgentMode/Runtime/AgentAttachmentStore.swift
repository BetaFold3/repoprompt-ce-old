import Foundation
import UniformTypeIdentifiers

package struct AgentAttachmentStore {
    private static let attachmentsDirectoryName = "agent_attachments"

    package struct ImportResult {
        package let attachment: AgentImageAttachment
        package let fileURL: URL
    }

    enum Error: LocalizedError {
        case invalidSourceURL
        case sourceIsNotImage
        case failedToCopy

        var errorDescription: String? {
            switch self {
            case .invalidSourceURL:
                "Image source must be a local file URL."
            case .sourceIsNotImage:
                "Only image files can be attached."
            case .failedToCopy:
                "Failed to import the selected image."
            }
        }
    }

    private let fileManager = FileManager.default

    package init() {}

    static func managedStorageRootURL(for workspaceDirectory: URL) -> URL {
        workspaceDirectory
            .appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    package static func abandonedAttachmentFinalizer(
        clearConsumedAttachments: Bool,
        workspaceDirectoryProvider: @escaping () -> URL?
    ) -> ([AgentImageAttachment]) -> Void {
        let store = AgentAttachmentStore()
        return { attachments in
            guard clearConsumedAttachments, !attachments.isEmpty,
                  let workspaceDirectory = workspaceDirectoryProvider()?.standardizedFileURL
            else { return }
            store.clearConsumedLocalFiles(attachments, workspaceDirectory: workspaceDirectory)
        }
    }

    package func importImageFile(sourceURL: URL, workspaceDirectory: URL) throws -> ImportResult {
        try importImageFile(sourceURL: sourceURL, storageRoot: Self.managedStorageRootURL(for: workspaceDirectory))
    }

    /// Same validation and copy as the workspace import, into a caller-owned storage root (used by
    /// the recovery store's durable per-session attachment directory).
    package func importImageFile(sourceURL: URL, storageRoot: URL) throws -> ImportResult {
        let sourceURL = sourceURL.standardizedFileURL
        guard sourceURL.isFileURL else {
            throw Error.invalidSourceURL
        }
        guard isImageFile(at: sourceURL) else {
            throw Error.sourceIsNotImage
        }

        try fileManager.createDirectory(at: storageRoot, withIntermediateDirectories: true)

        let fileExtension = normalizedFileExtension(for: sourceURL)
        let destinationURL = storageRoot
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw Error.failedToCopy
        }

        let attachment = AgentImageAttachment(
            source: .localFile(path: destinationURL.path),
            title: sourceURL.lastPathComponent
        )
        return ImportResult(attachment: attachment, fileURL: destinationURL)
    }

    package func clearConsumedLocalFiles(_ attachments: [AgentImageAttachment], workspaceDirectory: URL) {
        guard !attachments.isEmpty else { return }
        let storageRoot = Self.managedStorageRootURL(for: workspaceDirectory)
        let storagePrefix = storageRoot.path + "/"
        var localFilesToRemove: Set<URL> = []

        for attachment in attachments {
            guard case let .localFile(path) = attachment.source else { continue }
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            guard candidate.path.hasPrefix(storagePrefix) else { continue }
            localFilesToRemove.insert(candidate)
        }

        for fileURL in localFilesToRemove {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func normalizedFileExtension(for sourceURL: URL) -> String {
        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !ext.isEmpty {
            return ext
        }
        return "png"
    }

    private func isImageFile(at url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image)
        }
        return false
    }
}
