@testable import RepoPromptAgentCore
import XCTest

/// Step 4 authority amendment: `AgentRunOwnership.admissionSequence` is the process-wide
/// `AgentRunAdmissionSequence` ordinal, not the session's object-local `runAttemptGeneration`, so it
/// orders attempts across owner objects for the same tab. The allocator is never reset here and no
/// absolute value is asserted: other suites allocate from the same process-wide counter.
@MainActor
final class AgentRunAdmissionSequenceTests: XCTestCase {
    func testAdmissionsOfRecreatedOwnersOfOneTabKeepIncreasingWhileLocalCountersRestart() {
        let tabID = UUID()
        let original = AgentTabSession(tabID: tabID)
        original.testInstallPersistentSessionBinding(sessionID: UUID())
        let first = original.beginRunAttempt(source: "test.admissionSequence.original.first")
        let second = original.beginRunAttempt(source: "test.admissionSequence.original.second")
        XCTAssertEqual(original.runAttemptGeneration, 2, "The local lifecycle generation is unchanged")

        // The tab's owner is recreated (and rebound to another persistent session): its local
        // counter restarts, its admissions do not.
        let recreated = AgentTabSession(tabID: tabID)
        recreated.testInstallPersistentSessionBinding(sessionID: UUID())
        let third = recreated.beginRunAttempt(source: "test.admissionSequence.recreated.first")
        XCTAssertEqual(recreated.runAttemptGeneration, 1)
        let fourth = original.beginRunAttempt(source: "test.admissionSequence.original.third")

        let sequences = [first, second, third, fourth].map(\.admissionSequence)
        XCTAssertGreaterThan(first.admissionSequence, 0, "A session admission is never the 0 sentinel")
        XCTAssertEqual(sequences, sequences.sorted())
        XCTAssertEqual(Set(sequences).count, sequences.count, "Strictly increasing: no duplicate ordinal")
        XCTAssertEqual(third.binding.tabID, first.binding.tabID)
    }

    func testANonSessionAdmissionKeepsTheZeroSentinel() {
        var tracker = AgentRunLifecycleTracker()
        let ownership = tracker.begin(tabID: UUID(), persistentSessionID: nil)
        XCTAssertEqual(ownership.admissionSequence, 0)
        XCTAssertNil(ownership.richPresentationPolicy)
    }
}
