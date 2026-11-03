import Foundation
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import XCTest

private let draftSentinel = "DRAFT-SENTINEL secret message text"

/// Lossless restart F6: storage failures are classified at the store boundary from the underlying
/// Cocoa/POSIX error, and user-facing shutdown, commit-failure, and recovery text is plain: no enum
/// or `Domain=` syntax, no paths, and no draft content.
@MainActor
final class AgentRecoveryFailureWordingTests: XCTestCase {
    /// The live shape from `cycle8.H_shutdownFault`: Cocoa 513 wrapping POSIX EACCES, with a path.
    private static func permissionError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
            NSFilePathErrorKey: "/tmp/AgentRecovery/v1/sessions/\(draftSentinel).json",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [
                NSLocalizedDescriptionKey: "mktemp: Permission denied \(draftSentinel)"
            ])
        ])
    }

    private static func diskFullError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSFilePathErrorKey: "/tmp/AgentRecovery/v1/sessions/\(draftSentinel).json",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        ])
    }

    private struct UnknownFailure: Error, CustomStringConvertible {
        var description: String {
            "UnknownFailure(\(draftSentinel))"
        }
    }

    private func assertPlain(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for forbidden in [
            "Domain=", "Code=", "NSCocoaErrorDomain", "NSPOSIXErrorDomain", "AgentRecovery", "storageFailure",
            "store(", "evidenceNotPersisted", "composerNotPersisted", "UserInfo", "/tmp/", "mktemp",
            draftSentinel, "DRAFT-SENTINEL"
        ] {
            XCTAssertFalse(text.contains(forbidden), "\"\(forbidden)\" leaked into: \(text)", file: file, line: line)
        }
    }

    /// Drives the real store write path with a failing file operation and returns its error.
    private func storeWriteError(throwing injected: Error) async throws -> AgentRecoveryStoreError {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentRecoveryFailureWording-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AgentRecoveryStore(
            rootURL: root.appendingPathComponent("AgentRecovery/v1", isDirectory: true),
            fileOperations: AgentRecoveryStore.FileOperations(
                writeAtomically: { _, _ in throw injected },
                removeItem: { url in try FileManager.default.removeItem(at: url) }
            )
        )
        do {
            _ = try await store.recordCurrentLaunchRunning()
        } catch let error as AgentRecoveryStoreError {
            return error
        }
        XCTFail("The injected write failure must surface")
        throw CancellationError()
    }

    func testStoreBoundaryClassifiesPermissionDiskFullAndUnknownFailures() async throws {
        let permission = try await storeWriteError(throwing: Self.permissionError())
        XCTAssertEqual(permission.storageFailureCause, .permissionDenied)
        XCTAssertEqual(permission.category, .storage, "Failure classification is unchanged")
        if case let .storageFailure(detail, _) = permission {
            XCTAssertTrue(detail.contains("513"), "The raw detail is kept for logs: \(detail)")
        } else {
            XCTFail("\(permission)")
        }
        let diskFull = try await storeWriteError(throwing: Self.diskFullError())
        XCTAssertEqual(diskFull.storageFailureCause, .diskFull)
        let unknown = try await storeWriteError(throwing: UnknownFailure())
        XCTAssertEqual(unknown.storageFailureCause, .other)

        XCTAssertEqual(AgentRecoveryStorageFailureCause(classifying: CocoaError(.fileWriteOutOfSpace)), .diskFull)
        XCTAssertEqual(AgentRecoveryStorageFailureCause(classifying: CocoaError(.fileWriteVolumeReadOnly)), .permissionDenied)
        XCTAssertEqual(AgentRecoveryStorageFailureCause(classifying: POSIXError(.EDQUOT)), .diskFull)
        XCTAssertEqual(AgentRecoveryStorageFailureCause(classifying: POSIXError(.EPERM)), .permissionDenied)
        XCTAssertEqual(AgentRecoveryStorageFailureCause(classifying: CocoaError(.fileWriteUnknown)), .other)
        XCTAssertEqual(AgentRecoveryStoreError.storageFailure("opaque", cause: .other).storageFailureCause, .other, "An opaque string is never parsed")
    }

    func testShutdownPreparationTextIsPlainForPermissionDiskFullAndUnknownFailures() async throws {
        let cases: [(Error, String)] = [
            (Self.permissionError(), "can't access its data folder; check that folder's permissions and that its disk is writable"),
            (Self.diskFullError(), "the disk is full; free up some space"),
            (UnknownFailure(), "saving to disk failed")
        ]
        for (injected, expected) in cases {
            let storeError = try await storeWriteError(throwing: injected)
            let failure = AgentRecoveryControllerFailure.store(storeError)
            let composer = AgentModeViewModel.shutdownPreparationFailureText(.composer(.composerNotPersisted(failure)))
            let evidence = AgentModeViewModel.shutdownPreparationFailureText(.evidenceNotPersisted(failure))
            XCTAssertEqual(composer, "the message box could not be saved (\(failure.userFacingDescription)).")
            XCTAssertEqual(evidence, "its recovery state could not be saved (\(failure.userFacingDescription)).")
            for text in [composer, evidence] {
                XCTAssertTrue(text.contains(expected), text)
                assertPlain(text)
            }
        }
        XCTAssertEqual(
            AgentModeViewModel.shutdownPreparationFailureText(.composer(.composerNotPersisted(nil))),
            "the message box could not be saved."
        )
    }

    func testCommitFailureStartupAndRecoveryListTextIsPlain() async throws {
        let permissionStoreError = try await storeWriteError(throwing: Self.permissionError())
        let permission = AgentRecoveryControllerFailure.store(permissionStoreError)
        let delivery = AgentProviderHandoff.deliveryNotRecordedText(permission)
        XCTAssertEqual(
            delivery,
            "This message was not sent because its delivery could not be recorded (RepoPrompt can't access its data folder; check that folder's permissions and that its disk is writable). It stays saved."
        )
        XCTAssertEqual(
            AgentRecoveryAdmissionFailure.commitFailed(permission).dispatchFailureText,
            AgentRecoveryAdmissionFailure.deliveryNotRecordedText(),
            "One source for the delivery-not-recorded text"
        )
        XCTAssertEqual(
            AgentRecoveryAdmissionFailure.deliveryNotRecordedText(),
            "This message was not sent because its delivery could not be recorded. It stays saved."
        )
        assertPlain(delivery)
        assertPlain(AgentProviderHandoff.deliveryNotRecordedText(.lifecycleRejected("gate \(draftSentinel) /tmp/x")))

        let startupPermission = AgentRecoveryStorageFailureCause.startupFailureDescription(
            AgentRecoveryStoreError.classifiedStorageFailure(Self.permissionError())
        )
        XCTAssertEqual(
            startupPermission,
            "Recovery couldn't start: RepoPrompt can't access its data folder. Check that folder's permissions and that its disk is writable, then try again."
        )
        XCTAssertEqual(
            AgentRecoveryStorageFailureCause.startupFailureDescription(Self.diskFullError(), nextStep: "then reopen RepoPrompt"),
            "Recovery couldn't start: the disk is full. Free up some space, then reopen RepoPrompt."
        )
        let startupUnknown = AgentRecoveryStorageFailureCause.startupFailureDescription(UnknownFailure())
        XCTAssertEqual(startupUnknown, "Recovery couldn't start: RepoPrompt couldn't read or write its saved recovery data.")
        let startupUnreadable = AgentRecoveryStorageFailureCause.startupFailureDescription(
            AgentRecoveryStoreError.unreadableRecord(UUID(), .malformed("record.intents[0] \(draftSentinel)"))
        )
        for text in [startupPermission, startupUnknown, startupUnreadable] {
            assertPlain(text)
            XCTAssertTrue(text.hasPrefix("Recovery couldn't start: "), text)
            XCTAssertTrue(text.hasSuffix("."), text)
            XCTAssertFalse(text.contains(".."), text)
        }

        let diskFull = AgentRecoveryControllerFailure.store(.classifiedStorageFailure(Self.diskFullError()))
        XCTAssertEqual(AgentModeViewModel.recoveryListDescription(of: diskFull), "the disk is full; free up some space")
        XCTAssertEqual(
            AgentModeViewModel.recoveryListDescription(of: .store(.revisionConflict(expected: nil, actual: nil))),
            "saving to disk failed",
            "Non-storage store errors keep their earlier wording"
        )
    }

    /// Review A 01 / B R7: read denial and read-only volumes are "permission" failures, so the
    /// wording names neither writing alone nor a fix that only applies to permissions.
    func testReadDeniedAndReadOnlyFailuresUseNeutralPermissionWording() async throws {
        let readDenied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [
            NSFilePathErrorKey: "/tmp/AgentRecovery/v1/runtimes"
        ])
        let readOnlyVolume = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)
        let readOnlyPOSIX = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))
        ])
        let expected = "RepoPrompt can't access its data folder; check that folder's permissions and that its disk is writable"
        for injected in [readDenied, readOnlyVolume, readOnlyPOSIX] {
            let storeError = try await storeWriteError(throwing: injected)
            XCTAssertEqual(storeError.storageFailureCause, .permissionDenied, "\(injected)")
            let description = AgentRecoveryControllerFailure.store(storeError).userFacingDescription
            XCTAssertEqual(description, expected)
            XCTAssertFalse(description.contains("write to"), description)
            let shutdown = AgentModeViewModel.shutdownPreparationFailureText(.evidenceNotPersisted(.store(storeError)))
            XCTAssertEqual(shutdown, "its recovery state could not be saved (\(expected)).")
            assertPlain(shutdown)
        }
    }

    /// Review B R1: a refused scheduled admission is final (the schedule is marked failed), so no
    /// case promises a resume; the plain startup reason passes through; nothing raw is shown.
    func testScheduledAdmissionRefusalTextNamesItsCauseAndNeverPromisesAResume() {
        let startupReason = AgentRecoveryStorageFailureCause.startupFailureDescription(
            AgentRecoveryStoreError.classifiedStorageFailure(Self.diskFullError())
        )
        let hold = AgentRecoveryCrashHold(
            sessionID: UUID(),
            incarnationID: UUID(),
            transcriptResetGeneration: 0,
            uncertainRunAttemptIDs: [UUID()],
            uncertainIntentIDs: [],
            previousExitProvenClean: false
        )
        let refusals: [AgentRecoveryAdmissionRefusal] = [
            .startupNotReady, .startupFailed(startupReason), .restricted("Its recovery status is unknown."), .crashHeld(hold),
            .laneRetired, .bindingMismatch, .composerUnavailable(.store(.classifiedStorageFailure(Self.permissionError()))),
            .untrackedInput, .unsavedPredecessorInput, .resetPreparationInProgress, .shutdownInProgress,
            .recoveryActionInProgress
        ]
        for refusal in refusals {
            let text = AgentModeViewModel.scheduledRecoveryAdmissionRefusalMessage(refusal)
            XCTAssertTrue(text.contains("not sent"), "\(refusal.diagnosticName): \(text)")
            XCTAssertFalse(text.localizedCaseInsensitiveContains("paused until"), "\(refusal.diagnosticName): \(text)")
            XCTAssertFalse(text.contains(".."), text)
            XCTAssertFalse(text.contains("crashHeld") || text.contains("AgentRecoveryCrashHold"), text)
            assertPlain(text)
        }
        XCTAssertEqual(
            AgentModeViewModel.scheduledRecoveryAdmissionRefusalMessage(.startupFailed(startupReason)),
            "The scheduled message was not sent. Recovery couldn't start: the disk is full. Free up some space, then try again."
        )
    }
}
