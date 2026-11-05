import AppKit
import Foundation
import RepoPromptAgentCore

/// One composer document admission reservation, fenced to the exact destination captured when its
/// gesture began. It spans a dropped gesture's file-reference resolution (no `filenames` yet) and
/// the managed-store copy; while any reservation is registered for a tab, that tab cannot send or
/// schedule.
struct AgentComposerDocumentImport: Equatable {
    let id: UUID
    /// Empty while a dropped gesture's file references are still resolving.
    var filenames: [String]
    let sessionIdentity: ObjectIdentifier
    let persistentBinding: AgentPersistentSessionBindingIdentity?
    let bindingTransitionGeneration: UInt64
}

/// How a composer document admission settled.
enum AgentComposerDocumentImportOutcome: Equatable {
    /// The managed originals were attached to the destination composer.
    case attached([AgentDocumentAttachment])
    /// Nothing was attached; the composer shows `message`.
    case failed(message: String)
    /// The destination changed, closed, reset or froze before the admission settled: its composer
    /// was not touched. Any managed original copied by this import is retained, never attached.
    case discarded(reason: String)
    /// A dropped gesture held no PDF/HTML original: the reservation was released and the gesture
    /// went to the unchanged image path.
    case notDocuments
}

/// Presentation of a tab's document admissions and the last admission or import failure.
struct AgentComposerDocumentImportProps: Equatable {
    /// Names being copied (empty while a drop's file references are still resolving).
    let importingFilenames: [String]
    /// Any reservation is registered: send and schedule are refused.
    let isImporting: Bool
    let failureMessage: String?
}

/// Finder PDF/HTML admission for the Agent composer (paste and both drop surfaces).
///
/// Every gesture first reserves its destination synchronously (`reserveComposerDocumentAdmission`):
/// the tab, session object, persisted binding and binding generation. The reservation blocks send
/// and schedule (`documentImportInProgress`) until it settles and is re-checked before anything
/// touches a composer, so a destination that was reset, closed, replaced, re-bound or frozen in the
/// meantime is never changed, redirected or re-created. Gestures pass the explicit original file
/// URLs only. The originals are copied into the managed `AgentDocumentAttachmentStore` off the main
/// actor; only on success does the composer gain removable `AgentDocumentAttachment` references.
/// Typed input is never read or changed here.
extension AgentModeViewModel {
    static let composerDocumentImportInProgressMessage =
        "Wait for the attached documents to finish importing before sending."

    func isImportingComposerDocuments(tabID: UUID) -> Bool {
        composerDocumentImports[tabID]?.isEmpty == false
    }

    func composerDocumentImportProps(tabID: UUID?) -> AgentComposerDocumentImportProps? {
        guard let tabID else { return nil }
        let entries = composerDocumentImports[tabID] ?? []
        let failure = composerDocumentImportFailures[tabID]
        guard !entries.isEmpty || failure != nil else { return nil }
        return AgentComposerDocumentImportProps(
            importingFilenames: entries.flatMap(\.filenames),
            isImporting: !entries.isEmpty,
            failureMessage: failure
        )
    }

    /// Entry point for a claimed synchronous composer gesture (text-view paste, `readSelection` or
    /// drop). Returns whether an import started; a refusal (mixed selection, shutdown freeze, no
    /// destination) is shown and still claims the gesture.
    @discardableResult
    func admitComposerDocumentFiles(tabID: UUID, admission: ComposerDocumentFileAdmission) -> Bool {
        switch admission {
        case .notDocuments:
            return false
        case let .rejected(message):
            guard !isShutdownFrozen else { return false }
            showComposerDocumentImportFailure(message, tabID: tabID)
            return false
        case let .documents(urls):
            return attachDocumentFiles(tabID: tabID, urls: urls) != nil
        }
    }

    /// Surrounding SwiftUI drop of providers that advertise file URLs. The destination is reserved
    /// before the providers' original URLs load (asynchronously), so the reservation covers both the
    /// load and the copy. A drop with no PDF/HTML original releases it and runs `onNotDocuments`
    /// (the unchanged image path); a mixed drop is refused whole. Returns the task that settles the
    /// drop (tests await it), or `nil` when nothing was reserved (shutdown freeze, no destination).
    @discardableResult
    func admitDroppedComposerFiles(
        tabID: UUID,
        providers: [NSItemProvider],
        adapter: AgentImageInputAdapter,
        onNotDocuments: @escaping @MainActor () -> Void
    ) -> Task<AgentComposerDocumentImportOutcome, Never>? {
        guard let reservation = reserveComposerDocumentAdmission(tabID: tabID) else { return nil }
        return Task { @MainActor [weak self] in
            let references: [ComposerFileReference] = await withCheckedContinuation { continuation in
                adapter.loadDroppedFileReferences(from: providers) { continuation.resume(returning: $0) }
            }
            guard let self else { return .discarded(reason: Self.documentImportDestinationGoneReason) }
            return await settleDroppedComposerFiles(
                reservation,
                tabID: tabID,
                references: references,
                onNotDocuments: onNotDocuments
            )
        }
    }

    /// Starts importing `urls` (explicit original PDF/HTML files) for `tabID`'s composer. Returns the
    /// task that settles the import (tests await it), or `nil` when nothing started: no URLs, a
    /// shutdown freeze, or no destination session. The copy runs on the store actor.
    @discardableResult
    func attachDocumentFiles(tabID: UUID, urls: [URL]) -> Task<AgentComposerDocumentImportOutcome, Never>? {
        guard !urls.isEmpty, !isShutdownFrozen else { return nil }
        // A composer send or schedule in flight captures and clears its composer after awaits; a
        // document landing in that window could be dropped or rolled back, so it never starts.
        guard !isComposerSubmitInFlight else {
            showComposerDocumentImportFailure(Self.composerSubmitInFlightDocumentMessage, tabID: tabID)
            return nil
        }
        guard let reservation = reserveComposerDocumentAdmission(tabID: tabID) else { return nil }
        return startComposerDocumentImport(reservation, tabID: tabID, urls: urls)
    }

    /// Past tense: the row may outlive the send, so it describes the refused gesture, not the present.
    static let composerSubmitInFlightDocumentMessage =
        "A message was being sent from this window when these documents were added, so nothing was attached. Attach them again."

    /// Any composer send or schedule claim is active in this window (its composer capture and
    /// clear may still be ahead, possibly on a fresh first-send destination tab).
    var isComposerSubmitInFlight: Bool {
        sessions.values.contains { $0.activeComposerSubmitAttempt != nil }
    }

    /// Synchronously reserves `tabID`'s current composer for a document gesture: captures its
    /// session identity, persisted binding and binding generation, and blocks its send and schedule
    /// until the reservation settles. `nil` while frozen or without a destination session.
    func reserveComposerDocumentAdmission(tabID: UUID) -> AgentComposerDocumentImport? {
        guard !isShutdownFrozen, let session = session(for: tabID, createIfNeeded: true) else { return nil }
        let reservation = AgentComposerDocumentImport(
            id: UUID(),
            filenames: [],
            sessionIdentity: ObjectIdentifier(session),
            persistentBinding: session.persistentSessionBindingIdentity,
            bindingTransitionGeneration: session.bindingTransitionGeneration
        )
        composerDocumentImports[tabID, default: []].append(reservation)
        composerDocumentImportFailures[tabID] = nil
        syncComposerUIState(tabID: tabID)
        return reservation
    }

    /// Removes one document reference from the composer. The managed original is retained.
    func removePendingDocument(tabID: UUID, attachmentID: UUID) {
        guard let session = session(for: tabID, createIfNeeded: false) else { return }
        let beforeCount = session.pendingDocumentAttachments.count
        session.pendingDocumentAttachments.removeAll { $0.id == attachmentID }
        guard session.pendingDocumentAttachments.count != beforeCount else { return }
        session.isDirty = true
        updateBindingsFromSession(session)
        syncComposerUIState(tabID: tabID)
        scheduleSave(for: tabID)
    }

    func dismissComposerDocumentImportFailure(tabID: UUID) {
        guard composerDocumentImportFailures.removeValue(forKey: tabID) != nil else { return }
        syncComposerUIState(tabID: tabID)
    }

    /// A composer reset, or the importing row's Cancel control, invalidates this tab's reservations
    /// (resolving or copying): running copies are cancelled and every reservation settles as
    /// discarded. Typed text and already attached documents are untouched.
    func cancelComposerDocumentImports(tabID: UUID) {
        let entries = composerDocumentImports.removeValue(forKey: tabID)
        for entry in entries ?? [] {
            composerDocumentImportCopyTasks.removeValue(forKey: entry.id)?.cancel()
        }
        let hadImports = entries != nil
        let hadFailure = composerDocumentImportFailures.removeValue(forKey: tabID) != nil
        if hadImports || hadFailure {
            syncComposerUIState(tabID: tabID)
        }
    }

    nonisolated static let documentImportDestinationGoneReason =
        "The documents were not attached because their message box closed while they were importing."
    nonisolated static let documentImportDestinationChangedMessage =
        "The files were not attached because this session changed while they were being added. Paste or drop them again."
    nonisolated static let documentImportShutdownReason =
        "The documents were not attached because RepoPrompt is closing this window."

    func finishComposerDocumentImport(
        _ pending: AgentComposerDocumentImport,
        tabID: UUID,
        result: Result<[AgentDocumentAttachment], Error>
    ) -> AgentComposerDocumentImportOutcome {
        composerDocumentImportCopyTasks[pending.id] = nil
        let destination = composerDocumentReservationDestination(pending, tabID: tabID)
        releaseComposerDocumentReservation(pending, tabID: tabID)
        defer { syncComposerUIState(tabID: tabID) }
        guard case let .current(session) = destination else {
            return destination.discardOutcome
        }
        switch result {
        case let .failure(error):
            let message = Self.composerDocumentImportFailureMessage(for: error)
            composerDocumentImportFailures[tabID] = message
            return .failed(message: message)
        case let .success(attachments):
            guard !attachments.isEmpty else { return .attached([]) }
            session.pendingDocumentAttachments.append(contentsOf: attachments)
            session.isDirty = true
            updateBindingsFromSession(session)
            scheduleSave(for: tabID)
            return .attached(attachments)
        }
    }

    static func composerDocumentImportFailureMessage(for error: Error) -> String {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return "\(detail) Nothing was attached."
    }

    // MARK: Reservation internals

    private enum ComposerDocumentDestination {
        case current(AgentTabSession)
        case discarded(reason: String)

        var discardOutcome: AgentComposerDocumentImportOutcome {
            switch self {
            case .current:
                .discarded(reason: AgentModeViewModel.documentImportDestinationGoneReason)
            case let .discarded(reason):
                .discarded(reason: reason)
            }
        }
    }

    /// Whether `reservation` still names exactly the composer it captured. Never creates a session:
    /// a reset (reservation no longer registered) or closed tab is gone; a freeze refuses; a
    /// replaced session or a binding transition shows the changed message (image-only drops too).
    private func composerDocumentReservationDestination(
        _ reservation: AgentComposerDocumentImport,
        tabID: UUID
    ) -> ComposerDocumentDestination {
        guard composerDocumentImports[tabID]?.contains(where: { $0.id == reservation.id }) == true,
              let session = sessions[tabID]
        else {
            return .discarded(reason: Self.documentImportDestinationGoneReason)
        }
        guard !isShutdownFrozen else {
            return .discarded(reason: Self.documentImportShutdownReason)
        }
        guard ObjectIdentifier(session) == reservation.sessionIdentity,
              session.persistentSessionBindingIdentity == reservation.persistentBinding,
              session.bindingTransitionGeneration == reservation.bindingTransitionGeneration
        else {
            composerDocumentImportFailures[tabID] = Self.documentImportDestinationChangedMessage
            return .discarded(reason: Self.documentImportDestinationChangedMessage)
        }
        return .current(session)
    }

    private func releaseComposerDocumentReservation(_ reservation: AgentComposerDocumentImport, tabID: UUID) {
        guard var entries = composerDocumentImports[tabID] else { return }
        entries.removeAll { $0.id == reservation.id }
        composerDocumentImports[tabID] = entries.isEmpty ? nil : entries
    }

    /// Names the reservation's documents and copies them; the task settles through the fence.
    private func startComposerDocumentImport(
        _ reservation: AgentComposerDocumentImport,
        tabID: UUID,
        urls: [URL]
    ) -> Task<AgentComposerDocumentImportOutcome, Never> {
        if var entries = composerDocumentImports[tabID],
           let index = entries.firstIndex(where: { $0.id == reservation.id })
        {
            entries[index].filenames = urls.map(\.lastPathComponent)
            composerDocumentImports[tabID] = entries
            syncComposerUIState(tabID: tabID)
        }
        let store = documentAttachmentStore
        let task = Task { @MainActor [weak self] in
            let result: Result<[AgentDocumentAttachment], Error>
            do {
                result = try await .success(store.importDocuments(from: urls))
            } catch {
                result = .failure(error)
            }
            guard let self else { return AgentComposerDocumentImportOutcome.discarded(reason: Self.documentImportDestinationGoneReason) }
            return finishComposerDocumentImport(reservation, tabID: tabID, result: result)
        }
        // Registered before the task can run (both on the main actor), so Cancel always reaches it.
        composerDocumentImportCopyTasks[reservation.id] = task
        return task
    }

    private func settleDroppedComposerFiles(
        _ reservation: AgentComposerDocumentImport,
        tabID: UUID,
        references: [ComposerFileReference],
        onNotDocuments: @MainActor () -> Void
    ) async -> AgentComposerDocumentImportOutcome {
        let admission = ComposerDocumentFileAdmission.classify(references: references)
        // The destination is checked before any branch, so a drop whose composer was reset, closed,
        // replaced, re-bound or frozen while its URLs loaded never reaches the image path or a copy.
        // A replaced or re-bound session shows the changed message for any drop, image-only included.
        let destination = composerDocumentReservationDestination(reservation, tabID: tabID)
        guard case .current = destination else {
            releaseComposerDocumentReservation(reservation, tabID: tabID)
            syncComposerUIState(tabID: tabID)
            return destination.discardOutcome
        }
        switch admission {
        case .notDocuments:
            // Successfully resolved non-document drops keep their previous image behavior.
            releaseComposerDocumentReservation(reservation, tabID: tabID)
            syncComposerUIState(tabID: tabID)
            onNotDocuments()
            return .notDocuments
        case let .rejected(message):
            releaseComposerDocumentReservation(reservation, tabID: tabID)
            showComposerDocumentImportFailure(message, tabID: tabID)
            return .failed(message: message)
        case let .documents(urls):
            // A send or schedule claimed before this drop began may still capture and clear its
            // composer; the copy never starts then (the reservation blocks only later claims).
            guard !isComposerSubmitInFlight else {
                releaseComposerDocumentReservation(reservation, tabID: tabID)
                showComposerDocumentImportFailure(Self.composerSubmitInFlightDocumentMessage, tabID: tabID)
                return .failed(message: Self.composerSubmitInFlightDocumentMessage)
            }
            return await startComposerDocumentImport(reservation, tabID: tabID, urls: urls).value
        }
    }

    private func showComposerDocumentImportFailure(_ message: String, tabID: UUID) {
        composerDocumentImportFailures[tabID] = message
        syncComposerUIState(tabID: tabID)
    }
}
