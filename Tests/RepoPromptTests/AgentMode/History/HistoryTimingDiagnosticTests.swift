import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
import XCTest

/// Opt-in, read-only timing probe for the `history` tool against a real application
/// support store. Skipped unless `RPCE_HISTORY_TIMING_ROOT` names that root (the
/// directory containing `Workspaces/`). `HistorySessionScanner` only lists, stats, and
/// reads files, so this never mutates the store.
///
///     RPCE_HISTORY_TIMING_ROOT="$HOME/Library/Application Support/RepoPrompt CE" \
///       swift test --filter RepoPromptTests.HistoryTimingDiagnosticTests
final class HistoryTimingDiagnosticTests: XCTestCase {
    func testHistoryPhaseTimingAgainstRealStoreWhenEnabled() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["RPCE_HISTORY_TIMING_ROOT"], !rootPath.isEmpty else {
            throw XCTSkip("Set RPCE_HISTORY_TIMING_ROOT to an application-support root to run this diagnostic.")
        }
        let clock = TimingProbeClock()
        let scanner = HistorySessionScanner(
            // Explicit live-store injection: the default root resolves to a per-process
            // temporary directory under XCTest, so this opt-in probe must name the store.
            workspacesRoot: URL(fileURLWithPath: rootPath, isDirectory: true)
                .appendingPathComponent("Workspaces", isDirectory: true),
            now: { clock.now }
        )
        let search: [String: Value] = [
            "op": "search",
            "query": "RPCE_RESTART_ACCEPTANCE",
            "source": "all",
            "limit": 100
        ]
        let runs: [(label: String, args: [String: Value], expireTTL: Bool)] = [
            ("search cold", search, false),
            ("search warm (TTL hit)", search, false),
            ("list_sessions warm (TTL hit)", ["op": "list_sessions"], false),
            ("search warm index cache (TTL expired)", search, true)
        ]
        for run in runs {
            if run.expireTTL {
                clock.advance(by: 3600)
            }
            let diagnostics = HistoryExecutionDiagnostics()
            let reply = try await HistoryMCPToolService.execute(args: run.args, scanner: scanner, diagnostics: diagnostics)
            var outcome = "success"
            if case .error = reply {
                outcome = "invalid_arguments"
            }
            print("[HistoryTiming] \(run.label): \(diagnostics.summaryLine(outcome: outcome))")
            XCTAssertEqual(outcome, "success", run.label)
        }
    }
}

private final class TimingProbeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    var now: Date {
        lock.withLock { Date().addingTimeInterval(offset) }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { offset += seconds }
    }
}
