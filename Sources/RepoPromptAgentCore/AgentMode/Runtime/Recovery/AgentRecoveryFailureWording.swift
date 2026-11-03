import Foundation
import OSLog

// Lossless-restart F6: plain, actionable wording for recovery storage failures at the presentation
// boundary. User-facing text never carries raw Swift errors, enum syntax, `Domain=` text, file
// paths, or input content; the raw detail belongs in private logs.

/// Why a recovery-storage operation failed, classified once at the store boundary from the
/// underlying Cocoa or POSIX error so presentation never parses error text.
package enum AgentRecoveryStorageFailureCause: Equatable {
    case permissionDenied
    case diskFull
    case other

    /// Classifies an error and its underlying errors (bounded walk of `NSUnderlyingErrorKey`).
    package init(classifying error: Error) {
        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 4 {
            if let cause = Self.cause(domain: nsError.domain, code: nsError.code) {
                self = cause
                return
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        self = .other
    }

    private static func cause(domain: String, code: Int) -> Self? {
        switch domain {
        case NSCocoaErrorDomain:
            switch code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, NSFileWriteVolumeReadOnlyError:
                .permissionDenied
            case NSFileWriteOutOfSpaceError:
                .diskFull
            default:
                nil
            }
        case NSPOSIXErrorDomain:
            switch Int32(truncatingIfNeeded: code) {
            case EACCES, EPERM, EROFS:
                .permissionDenied
            case ENOSPC, EDQUOT:
                .diskFull
            default:
                nil
            }
        default:
            nil
        }
    }

    /// Plain, actionable clause (no trailing period) for user-facing text.
    package var userFacingDescription: String {
        switch self {
        case .permissionDenied:
            // Covers read denial and read-only volumes too, so the wording is operation-neutral.
            "RepoPrompt can't access its data folder; check that folder's permissions and that its disk is writable"
        case .diskFull:
            "the disk is full; free up some space"
        case .other:
            "saving to disk failed"
        }
    }

    /// Fixed, content-free token for logs.
    package var diagnosticName: String {
        switch self {
        case .permissionDenied: "permission_denied"
        case .diskFull: "disk_full"
        case .other: "other"
        }
    }

    /// The typed cause carried by a store storage failure, else a classification of `error`.
    package static func of(_ error: Error) -> Self {
        (error as? AgentRecoveryStoreError)?.storageFailureCause ?? Self(classifying: error)
    }

    /// One complete, self-contained sentence (or two) for an error that ended recovery startup or
    /// composition. `nextStep` completes the remedy ("then try again", "then reopen RepoPrompt").
    /// Wrappers append further sentences after it; they never add punctuation to it.
    package static func startupFailureDescription(_ error: Error, nextStep: String = "then try again") -> String {
        switch of(error) {
        case .permissionDenied:
            "Recovery couldn't start: RepoPrompt can't access its data folder. Check that folder's permissions and that its disk is writable, \(nextStep)."
        case .diskFull:
            "Recovery couldn't start: the disk is full. Free up some space, \(nextStep)."
        case .other:
            "Recovery couldn't start: RepoPrompt couldn't read or write its saved recovery data."
        }
    }
}

/// Always-on diagnostics for recovery failures whose user-facing text is plain wording: a fixed
/// public reason and cause, with the raw failure (paths, identifiers; never input content) private.
package enum AgentRecoveryFailureDiagnostics {
    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "RecoveryFailure")

    package static func startupFailed(_ error: Error) {
        let cause = AgentRecoveryStorageFailureCause.of(error)
        logger.notice(
            "recovery_startup_failed cause=\(cause.diagnosticName, privacy: .public) detail=\(String(describing: error), privacy: .private)"
        )
    }

    package static func runtimeRecordsUnreadable(_ error: Error) {
        let cause = AgentRecoveryStorageFailureCause.of(error)
        logger.notice(
            "runtime_records_unreadable cause=\(cause.diagnosticName, privacy: .public) detail=\(String(describing: error), privacy: .private)"
        )
    }

    /// A user-facing message at `site` (a fixed token) withheld this failure's raw detail.
    package static func presentationFailure(site: String, failure: some Any) {
        logger.notice(
            "presentation_failure site=\(site, privacy: .public) detail=\(String(describing: failure), privacy: .private)"
        )
    }

    /// A shutdown-preparation (or finalization) blocker; `reason` is a fixed token.
    package static func shutdownBlocked(reason: String, tabID: UUID, failure: AgentRecoveryControllerFailure?) {
        logger.notice(
            "shutdown_blocked reason=\(reason, privacy: .public) tab=\(tabID.uuidString, privacy: .public) failure=\(failure?.diagnosticName ?? "none", privacy: .public) detail=\(failure.map { String(describing: $0) } ?? "none", privacy: .private)"
        )
    }
}

package extension AgentRecoveryAdmissionFailure {
    /// The single source of the "delivery could not be recorded" text (run-service commit failure,
    /// runner run-attempt failures, headless). `cause` is plain wording, never a raw failure.
    static func deliveryNotRecordedText(cause: String? = nil) -> String {
        "This message was not sent because its delivery could not be recorded\(cause.map { " (\($0))" } ?? ""). It stays saved."
    }
}

package extension AgentRecoveryAdmissionRefusal {
    /// Fixed, content-free token for logs.
    var diagnosticName: String {
        switch self {
        case .startupNotReady: "startup_not_ready"
        case .startupFailed: "startup_failed"
        case .restricted: "restricted"
        case .crashHeld: "crash_held"
        case .laneRetired: "lane_retired"
        case .bindingMismatch: "binding_mismatch"
        case .composerUnavailable: "composer_unavailable"
        case .untrackedInput: "untracked_input"
        case .unsavedPredecessorInput: "unsaved_predecessor_input"
        case .resetPreparationInProgress: "reset_preparation_in_progress"
        case .shutdownInProgress: "shutdown_in_progress"
        case .recoveryActionInProgress: "recovery_action_in_progress"
        }
    }
}

package extension AgentRecoveryStoreError {
    /// A storage failure carrying the raw description (for logs) and its typed cause.
    static func classifiedStorageFailure(_ error: Error) -> AgentRecoveryStoreError {
        .storageFailure(String(describing: error), cause: AgentRecoveryStorageFailureCause(classifying: error))
    }

    /// The typed cause of a storage failure; nil for every other store error.
    var storageFailureCause: AgentRecoveryStorageFailureCause? {
        if case let .storageFailure(_, cause) = self { cause } else { nil }
    }
}

package extension AgentRecoveryControllerFailure {
    /// Plain wording only (no trailing period): raw store errors and gate reasons can describe
    /// local paths and identifiers, so they never reach user-facing text.
    var userFacingDescription: String {
        switch self {
        case let .store(.storageFailure(_, cause)):
            cause.userFacingDescription
        case .store:
            "saving to disk failed"
        case .lifecycleRejected:
            "the session changed"
        case .retired:
            "the session moved to another tab or window"
        case .noHeldComposer, .heldInputChanged:
            "it changed while it was being saved"
        case .liveComposerHasUnsavedContent:
            "the message box has newer text"
        case .composerChangedDuringRestore:
            "the message box changed while the draft was being restored"
        }
    }

    /// Fixed, content-free token for logs (the raw detail is logged privately beside it).
    var diagnosticName: String {
        switch self {
        case let .store(.storageFailure(_, cause)): "store_storage_\(cause.diagnosticName)"
        case .store: "store"
        case .lifecycleRejected: "lifecycle_rejected"
        case .retired: "retired"
        case .noHeldComposer: "no_held_composer"
        case .heldInputChanged: "held_input_changed"
        case .liveComposerHasUnsavedContent: "live_composer_has_unsaved_content"
        case .composerChangedDuringRestore: "composer_changed_during_restore"
        }
    }
}
