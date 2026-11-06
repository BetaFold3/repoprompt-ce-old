import Foundation
import MCP
@testable import RepoPromptAgentCore
@testable import RepoPromptApp
@testable import RepoPromptPlatform
@testable import RepoPromptUI
@testable import RepoPromptWorkspace
import XCTest

final class ReadFileFenceBoundaryTests: XCTestCase {
    func testFencePreservesSourceBytesWithoutAddingAnEmptySourceLine() {
        let cases: [(label: String, content: String, fence: String)] = [
            ("empty", "", "```swift\n```"),
            ("unterminated", "value", "```swift\nvalue\n```"),
            ("LF", "value\n", "```swift\nvalue\n```"),
            ("CRLF", "value\r\n", "```swift\nvalue\r\n```"),
            ("lone CR", "value\r", "```swift\nvalue\r\n```"),
            ("trailing blank", "value\n\n", "```swift\nvalue\n\n```"),
            ("blank only", "\n", "```swift\n\n```"),
            ("trailing spaces", "value  ", "```swift\nvalue  \n```"),
            ("spaces before LF", "value  \n", "```swift\nvalue  \n```")
        ]
        for entry in cases {
            let result = ToolOutputFormatter.readFile(
                path: "Fixture.swift", first: 1, last: 1, total: 1,
                language: "swift", message: nil, content: entry.content
            )
            let expected = "## File Read ✅\n- **Path**: `Fixture.swift`\n- **Lines**: 1–1 of 1\n\n" + entry.fence
            XCTAssertEqual(Array(result.utf8), Array(expected.utf8), entry.label)
        }
    }

    func testSliceBoundaryIsIdenticalAcrossLegacyAndStructuredResultsWithoutChangingTheDTO() throws {
        // Saved Sonnet n12 read_file range: the actual next line (457) is another closing
        // brace, not the blank line the old unconditional fence separator appeared to show.
        let content = [
            "                    continue",
            "                }",
            "                let removal = SliceRangeMath.normalize(entry.ranges)",
            "                guard !baseRanges.isEmpty else { continue }",
            "                let next = removal.isEmpty ? [] : SliceRangeMath.subtract(baseRanges, removing: removal)",
            "                if next.isEmpty { slices.removeValue(forKey: full) } else { slices[full] = next }",
            "            }"
        ].joined(separator: "\n") + "\n"
        let value = try Value(ToolResultDTOs.ReadFileReply(
            content: content, totalLines: 500, firstLine: 450, lastLine: 456
        ))
        let args: [String: Value] = ["path": .string("Fixture.swift")]
        let off = ServerNetworkManager.makeToolResult(
            toolName: MCPWindowToolName.readFile, args: args, value: value, structured: false
        )
        let on = ServerNetworkManager.makeToolResult(
            toolName: MCPWindowToolName.readFile, args: args, value: value, structured: true
        )
        let expected = "## File Read ✅\n- **Path**: `Fixture.swift`\n- **Lines**: 450–456 of 500\n\n```swift\n"
            + content + "```"
        for result in [off, on] {
            let texts = result.content.compactMap { block -> String? in
                if case let .text(text, _, _) = block { return text }
                return nil
            }
            XCTAssertEqual(texts.count, 1)
            XCTAssertEqual(texts.first.map { Array($0.utf8) }, Array(expected.utf8))
        }
        XCTAssertNil(off.structuredContent)
        XCTAssertEqual(on.structuredContent, value)
    }
}
