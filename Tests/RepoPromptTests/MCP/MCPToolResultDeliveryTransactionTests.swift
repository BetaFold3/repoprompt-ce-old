import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

/// Final tool-result handoff boundary (plan §6.2): every registered participant is either settled
/// (threaded through the returned value) or abandoned, exactly once, and never both.
final class MCPToolResultDeliveryTransactionTests: XCTestCase {
    func testSettleThreadsTheValueThroughParticipantsInOrderAndNeverAbandons() async {
        let transaction = MCPToolResultDeliveryTransaction()
        let recorder = Recorder()
        for name in ["first", "second"] {
            transaction.register(
                settle: { value, handOff in
                    recorder.append("\(name).settle(\(handOff))")
                    guard case var .object(object) = value else { return value }
                    object[name] = .bool(true)
                    return .object(object)
                },
                abandon: { recorder.append("\(name).abandon") }
            )
        }

        let settled = await transaction.settle(.object(["ok": .bool(true)]), handOff: true)
        XCTAssertEqual(settled, .object(["ok": .bool(true), "first": .bool(true), "second": .bool(true)]))
        XCTAssertEqual(recorder.events, ["first.settle(true)", "second.settle(true)"])

        transaction.abandon()
        let again = await transaction.settle(.object([:]), handOff: true)
        XCTAssertEqual(again, .object([:]), "A second settle never reaches a participant again")
        XCTAssertEqual(recorder.events, ["first.settle(true)", "second.settle(true)"], "Abandon after settle is a no-op")
    }

    func testUnannotatedRemovesEveryOpenAttachmentWithoutClosingTheTransaction() async {
        let transaction = MCPToolResultDeliveryTransaction()
        let recorder = Recorder()
        for name in ["first", "second"] {
            transaction.register(
                unannotate: { value in
                    guard case var .object(object) = value else { return value }
                    object.removeValue(forKey: name)
                    return .object(object)
                },
                settle: { value, handOff in
                    recorder.append("\(name).settle(\(handOff))")
                    return value
                },
                abandon: { recorder.append("\(name).abandon") }
            )
        }
        let attached: Value = .object(["ok": .bool(true), "first": .bool(true), "second": .bool(true)])

        // Completion observers see the result without any pending attachment.
        XCTAssertEqual(transaction.unannotated(attached), .object(["ok": .bool(true)]))
        XCTAssertTrue(recorder.events.isEmpty, "Unannotating never settles or abandons a participant")

        // The final handoff still receives the attached value.
        let settled = await transaction.settle(attached, handOff: true)
        XCTAssertEqual(settled, attached)
        XCTAssertEqual(recorder.events, ["first.settle(true)", "second.settle(true)"])
        XCTAssertEqual(transaction.unannotated(attached), attached, "A closed transaction has no open attachment")
    }

    func testCancelledSettlePassesHandOffFalse() async {
        let transaction = MCPToolResultDeliveryTransaction()
        let recorder = Recorder()
        transaction.register(
            settle: { value, handOff in
                recorder.append("settle(\(handOff))")
                return handOff ? value : .object([:])
            },
            abandon: { recorder.append("abandon") }
        )
        let settled = await transaction.settle(.object(["notice": .string("x")]), handOff: false)
        XCTAssertEqual(settled, .object([:]))
        XCTAssertEqual(recorder.events, ["settle(false)"])
    }

    func testAbandonReleasesEachParticipantOnceAndALaterSettleReturnsTheValueUnchanged() async {
        let transaction = MCPToolResultDeliveryTransaction()
        let recorder = Recorder()
        for name in ["first", "second"] {
            transaction.register(
                settle: { _, _ in
                    recorder.append("\(name).settle")
                    return .null
                },
                abandon: { recorder.append("\(name).abandon") }
            )
        }

        transaction.abandon()
        transaction.abandon()
        XCTAssertEqual(recorder.events, ["first.abandon", "second.abandon"])
        let value: Value = .object(["ok": .bool(true)])
        let settled = await transaction.settle(value, handOff: true)
        XCTAssertEqual(settled, value)
        XCTAssertEqual(recorder.events, ["first.abandon", "second.abandon"])
    }

    func testReleaseAttachmentsStripsInOrderAndAbandonsWithoutEverSettling() async {
        let transaction = MCPToolResultDeliveryTransaction()
        let recorder = Recorder()
        for name in ["first", "second"] {
            transaction.register(
                unannotate: { value in
                    recorder.append("\(name).unannotate")
                    guard case var .object(object) = value else { return value }
                    object.removeValue(forKey: name)
                    return .object(object)
                },
                settle: { value, _ in
                    recorder.append("\(name).settle")
                    return value
                },
                abandon: { recorder.append("\(name).abandon") }
            )
        }
        let attached: Value = .object(["ok": .bool(true), "first": .bool(true), "second": .bool(true)])

        XCTAssertEqual(transaction.releaseAttachments(from: attached), .object(["ok": .bool(true)]))
        XCTAssertEqual(
            recorder.events,
            ["first.unannotate", "second.unannotate", "first.abandon", "second.abandon"]
        )
        // Closed: later settle, abandon, or release never reach a participant again.
        let settled = await transaction.settle(attached, handOff: true)
        XCTAssertEqual(settled, attached)
        transaction.abandon()
        XCTAssertEqual(transaction.releaseAttachments(from: attached), attached)
        XCTAssertEqual(recorder.events.count, 4)
    }

    func testRegistrationAfterTheTransactionClosedAbandonsImmediately() async {
        for closesBySettle in [true, false] {
            let transaction = MCPToolResultDeliveryTransaction()
            let recorder = Recorder()
            if closesBySettle {
                _ = await transaction.settle(.null, handOff: true)
            } else {
                transaction.abandon()
            }
            transaction.register(
                settle: { value, _ in
                    recorder.append("settle")
                    return value
                },
                abandon: { recorder.append("abandon") }
            )
            XCTAssertEqual(recorder.events, ["abandon"], "closesBySettle=\(closesBySettle)")
            _ = await transaction.settle(.null, handOff: true)
            transaction.abandon()
            XCTAssertEqual(recorder.events, ["abandon"], "closesBySettle=\(closesBySettle)")
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ event: String) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
