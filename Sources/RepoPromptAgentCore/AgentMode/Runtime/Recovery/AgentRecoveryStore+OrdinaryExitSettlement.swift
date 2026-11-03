import Foundation
import os

// Lossless-restart Step 11 (O51): a one-time startup settlement of `deliveryUnknown` intents an
// earlier build left after a run RepoPrompt itself ended normally (its own steer or Stop
// interrupted the message's turn, which that build recorded as unknown). Only intents that
// `AgentRecoveryRecord.ordinaryExitSettlementQualifies` accepts, all of whose attempts were
// dispatched before the pass's cutoff, are touched; crash, quit, user-cancel, provider-loss,
// legacy, failed, open and otherwise uncertain evidence stays as it is.

package extension AgentRecoveryStore {
    /// Intent extras member recording why the settlement accepted the intent.
    static let ordinaryExitSettlementExtrasKey = "deliverySettlement"
    /// `deliverySettlement.reason` (and the settled attempt outcome's `settledBy`) value.
    static let ordinaryExitSettlementReason = "ordinaryRunExit"
    /// H1: hard upper bound (2026-11-06T00:00:00Z): no attempt dispatched on or after it is ever
    /// settled, whatever marker or launch-mark evidence was lost (e.g. across a downgrade).
    static let ordinaryExitSettlementLatestCutoff = AgentRecoveryTimestamp(millisecondsSince1970: 1_793_923_200_000)

    /// `…/AgentRecovery/v1/ordinary-exit-settlement.json`: `{cutoffMs, completed: false}` is written
    /// before any record is modified; `completed: true` only once every candidate record was read
    /// and every qualifying one written. An unfinished pass resumes next launch with the stored
    /// cutoff, so attempts a later launch dispatched are never settled. The cutoff is never later
    /// than the first settlement launch's start, which every launch mark carries forward
    /// (`ordinaryExitSettlementLaunchCutoff`), even when this marker was never written.
    nonisolated var ordinaryExitSettlementMarkerURL: URL {
        rootURL.appendingPathComponent("ordinary-exit-settlement.json")
    }

    struct OrdinaryExitSettlementResult: Equatable {
        /// `false` when nothing was read or written: an earlier launch completed the pass, its
        /// marker could not be read, or the in-progress marker could not be written.
        package let ran: Bool
        /// The completion marker was written: every candidate was read and written.
        package let completed: Bool
        package let settledIntentIDs: [UUID]
        package let failedSessionIDs: [UUID]
    }

    /// Runs the O51 settlement until it completes once (call during startup, before discovery
    /// and before admission opens). Each qualifying intent becomes `providerAccepted`; each of its
    /// `deliveryUnknown` attempts keeps that outcome as `supersededOutcome` under a
    /// `providerAccepted` outcome marked `settledBy: ordinaryRunExit` (an attempt that already has
    /// a `supersededOutcome` is not rewritten), and the intent records `deliverySettlement`
    /// (reason and time). Records with nothing qualifying are not rewritten; unreadable or future
    /// records are never touched (and keep the pass from completing). Idempotent: a settled
    /// intent no longer qualifies.
    @discardableResult
    func settleOrdinaryExitDeliveryUnknownIntentsOnce() -> OrdinaryExitSettlementResult {
        let notRun = OrdinaryExitSettlementResult(ran: false, completed: false, settledIntentIDs: [], failedSessionIDs: [])
        let cutoff: AgentRecoveryTimestamp
        switch readOrdinaryExitSettlementMarker() {
        case let .present(marker) where marker.completed:
            return OrdinaryExitSettlementResult(ran: false, completed: true, settledIntentIDs: [], failedSessionIDs: [])
        case let .present(marker):
            cutoff = Self.earlier(
                Self.earlier(marker.cutoff, ordinaryExitSettlementLaunchCutoff),
                Self.ordinaryExitSettlementLatestCutoff
            )
        case .unreadable:
            // Without its cutoff an unfinished pass cannot tell earlier attempts from later ones.
            Self.ordinaryExitSettlementLogger.error("O51 settlement marker unreadable; not settling")
            return notRun
        case .absent:
            // The first settlement launch's start, carried in every launch mark since (G4), so a
            // pass whose in-progress marker was never written cannot re-take a later cutoff.
            // Without one, this launch's start: the pass runs before any of its own dispatches.
            cutoff = Self.earlier(
                ordinaryExitSettlementLaunchCutoff ?? AgentRecoveryTimestamp(now()),
                Self.ordinaryExitSettlementLatestCutoff
            )
            guard writeOrdinaryExitSettlementMarker(cutoff: cutoff, completed: false, settled: 0, failed: 0) else {
                return notRun
            }
        }

        let sessionIDs: [UUID]
        do {
            sessionIDs = try FileManager.default.contentsOfDirectory(
                at: sessionsDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).compactMap { url -> UUID? in
                guard url.pathExtension == "json" else { return nil }
                let stem = url.deletingPathExtension().lastPathComponent
                guard let id = UUID(uuidString: stem), id.uuidString == stem else { return nil }
                return id
            }.sorted { $0.uuidString < $1.uuidString }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            sessionIDs = []
        } catch {
            // Not an absent directory: no completion; the stored cutoff is reused next launch.
            Self.ordinaryExitSettlementLogger.error(
                "O51 settlement enumeration failed error=\(String(describing: error), privacy: .public)"
            )
            return OrdinaryExitSettlementResult(ran: true, completed: false, settledIntentIDs: [], failedSessionIDs: [])
        }

        var settled: [UUID] = []
        var failed: [UUID] = []
        for sessionID in sessionIDs {
            let record: AgentRecoveryRecord
            switch read(sessionID: sessionID) {
            case .absent:
                continue
            case let .supported(supported):
                record = supported
            case .preserved:
                failed.append(sessionID)
                continue
            }
            let qualifying = record.intents
                .filter { Self.ordinaryExitSettlementQualifies($0.intentID, in: record, cutoff: cutoff) }
                .map(\.intentID)
            guard !qualifying.isEmpty else { continue }
            do {
                try settle(qualifying, in: record)
                settled += qualifying
            } catch {
                failed.append(sessionID)
                Self.ordinaryExitSettlementLogger.error(
                    "O51 settlement write failed session=\(sessionID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        let completed = failed.isEmpty
            && writeOrdinaryExitSettlementMarker(cutoff: cutoff, completed: true, settled: settled.count, failed: 0)
        return OrdinaryExitSettlementResult(ran: true, completed: completed, settledIntentIDs: settled, failedSessionIDs: failed)
    }

    private static let ordinaryExitSettlementLogger = Logger(subsystem: "com.repoprompt.agents", category: "RecoverySettlement")

    /// O51 qualification plus the cutoff: every attempt was dispatched before it, and none already
    /// carries a `supersededOutcome` (such an intent is skipped whole, never left mixed).
    private static func ordinaryExitSettlementQualifies(
        _ intentID: UUID,
        in record: AgentRecoveryRecord,
        cutoff: AgentRecoveryTimestamp
    ) -> Bool {
        record.ordinaryExitSettlementQualifies(intentID: intentID)
            && record.attempts(forIntent: intentID).allSatisfy {
                $0.dispatchedAt.millisecondsSince1970 < cutoff.millisecondsSince1970
                    && $0.supersededOutcome == nil
            }
    }

    private static func earlier(_ lhs: AgentRecoveryTimestamp, _ rhs: AgentRecoveryTimestamp?) -> AgentRecoveryTimestamp {
        guard let rhs, rhs.millisecondsSince1970 < lhs.millisecondsSince1970 else { return lhs }
        return rhs
    }

    private func settle(_ intentIDs: [UUID], in record: AgentRecoveryRecord) throws {
        let ids = Set(intentIDs)
        let timestamp = AgentRecoveryTimestamp(now())
        let fact: AgentRecoveryJSONValue = .object([
            "reason": .string(Self.ordinaryExitSettlementReason),
            "recordedAt": .number(Decimal(timestamp.millisecondsSince1970))
        ])
        let intents = record.intents.map { intent -> AgentRecoveryIntent in
            guard ids.contains(intent.intentID) else { return intent }
            var intent = intent
            intent.deliveryState = .providerAccepted
            intent.extras[Self.ordinaryExitSettlementExtrasKey] = fact
            return intent
        }
        let attempts = record.attempts.map { attempt -> AgentRecoveryAttempt in
            guard ids.contains(attempt.intentID),
                  attempt.supersededOutcome == nil,
                  attempt.outcome?.outcome == .deliveryUnknown
            else { return attempt }
            var attempt = attempt
            attempt.supersededOutcome = attempt.outcome
            attempt.outcome = AgentRecoveryAttemptOutcome(
                outcome: .providerAccepted,
                recordedAt: timestamp,
                extras: ["settledBy": .string(Self.ordinaryExitSettlementReason)]
            )
            return attempt
        }
        _ = try replace(
            record,
            binding: AgentRecoveryLifecycleBinding(
                sessionID: record.sessionID,
                incarnationID: record.incarnationID,
                transcriptResetGeneration: record.transcriptResetGeneration
            ),
            composer: record.composer,
            intents: intents,
            attempts: attempts,
            runAttempts: record.runAttempts
        )
    }

    private struct OrdinaryExitSettlementMarker {
        let cutoff: AgentRecoveryTimestamp
        let completed: Bool
    }

    private enum OrdinaryExitSettlementMarkerState {
        case absent
        case present(OrdinaryExitSettlementMarker)
        case unreadable
    }

    private func readOrdinaryExitSettlementMarker() -> OrdinaryExitSettlementMarkerState {
        let data: Data
        do {
            data = try Data(contentsOf: ordinaryExitSettlementMarkerURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return .absent
        } catch {
            return .unreadable
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cutoff = (object["cutoffMs"] as? NSNumber)?.int64Value,
              let completed = object["completed"] as? Bool
        else { return .unreadable }
        return .present(OrdinaryExitSettlementMarker(
            cutoff: AgentRecoveryTimestamp(millisecondsSince1970: cutoff),
            completed: completed
        ))
    }

    /// Whether the marker was written.
    private func writeOrdinaryExitSettlementMarker(
        cutoff: AgentRecoveryTimestamp,
        completed: Bool,
        settled: Int,
        failed: Int
    ) -> Bool {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "cutoffMs": NSNumber(value: cutoff.millisecondsSince1970),
            "completed": completed,
            "recordedAtMs": NSNumber(value: AgentRecoveryTimestamp(now()).millisecondsSince1970),
            "settledIntentCount": settled,
            "failedSessionCount": failed
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileOperations.writeAtomically(data, ordinaryExitSettlementMarkerURL)
            return true
        } catch {
            // Not written: an unstarted pass does not start; an unfinished one resumes next launch.
            Self.ordinaryExitSettlementLogger.error(
                "O51 settlement marker write failed completed=\(completed, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }
}
