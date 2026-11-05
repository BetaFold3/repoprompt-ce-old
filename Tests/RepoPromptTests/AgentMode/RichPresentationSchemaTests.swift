import Foundation
@testable import RepoPromptAgentCore
import XCTest

final class RichPresentationSchemaTests: XCTestCase {
    // MARK: Fixtures

    private func lineChart(x: [Any]? = nil, series: [[String: Any]]? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var content: [String: Any] = [
            "kind": "chart",
            "chart_type": "line",
            "x_label": "Time",
            "unit": "requests/s",
            "x": x ?? ["2026-11-05T10:00:00Z", "2026-11-05T11:00:00.25+00:30", "2026-11-05T12:00:00z"],
            "series": series ?? [
                ["name": "API", "y": [1.5, NSNull(), 3]],
                ["name": "Web", "y": [2, 4, -0.5]]
            ],
            "sources": [["label": "Local benchmark"]]
        ]
        content.merge(extra) { _, new in new }
        return ["version": 1, "title": "Throughput", "content": content]
    }

    private func barChart(x: [Any]) -> [String: Any] {
        var input = lineChart()
        var content = input["content"] as! [String: Any]
        content["chart_type"] = "bar"
        content["x"] = x
        content["series"] = [["name": "Count", "y": x.map { _ in 1 }]]
        input["content"] = content
        return input
    }

    private func article(headline: String = "Headline", body: String = "Body", image: [String: Any]? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = [
            "headline": headline,
            "body": body,
            "sources": [["label": "Example", "url": "https://news.example.com/a?b=1"]]
        ]
        if let image { value["image"] = image }
        value.merge(extra) { _, new in new }
        return value
    }

    private func briefing(sections: [[String: Any]]? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var content: [String: Any] = [
            "kind": "briefing",
            "date": "2028-02-29",
            "sections": sections ?? [["heading": "World", "articles": [article()]]]
        ]
        content.merge(extra) { _, new in new }
        return ["version": 1, "title": "Morning briefing", "content": content]
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func validate(_ object: Any) throws -> RichPresentationInput {
        try RichPresentationValidator.validateInput(data: data(object))
    }

    private func assertRejects(
        _ object: Any,
        field: String,
        code: RichPresentationValidationError.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try validate(object)
            XCTFail("Expected rejection at \(field)", file: file, line: line)
        } catch let error as RichPresentationValidationError {
            XCTAssertEqual(error.field, field, error.description, file: file, line: line)
            XCTAssertEqual(error.code, code, error.description, file: file, line: line)
            XCTAssertFalse(error.message.isEmpty, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func withContent(_ input: [String: Any], _ mutate: (inout [String: Any]) -> Void) -> [String: Any] {
        var input = input
        var content = input["content"] as! [String: Any]
        mutate(&content)
        input["content"] = content
        return input
    }

    // MARK: Valid input

    func testValidLineChartDecodesAndRoundTrips() throws {
        let input = try validate(lineChart())
        XCTAssertEqual(input.version, 1)
        XCTAssertEqual(input.kind, .chart)
        guard case let .chart(chart) = input.content else { return XCTFail("expected chart") }
        XCTAssertEqual(chart.chartType, .line)
        XCTAssertEqual(chart.series[0].y, [1.5, nil, 3])
        XCTAssertNil(chart.sources[0].url)

        let encoded = try JSONEncoder().encode(input)
        XCTAssertEqual(try RichPresentationValidator.validateInput(data: encoded), input)
        XCTAssertEqual(try JSONDecoder().decode(RichPresentationInput.self, from: encoded), input)
    }

    func testValidBriefingPreservesPlainTextExactly() throws {
        let body = "  First paragraph with <b>markup</b> and **stars**.\n\nSecond paragraph.  "
        let input = try validate(briefing(
            sections: [
                ["heading": "World", "articles": [article(headline: " Lead ", body: body, image: ["url": "not a url", "alt": ""])]],
                ["heading": "Tech", "articles": [article(headline: "Second"), article(headline: "Third")]]
            ],
            extra: ["deck": "Today\n\nin brief"]
        ))
        guard case let .briefing(briefing) = input.content else { return XCTFail("expected briefing") }
        XCTAssertEqual(briefing.deck, "Today\n\nin brief")
        XCTAssertEqual(briefing.sections[0].articles[0].headline, " Lead ")
        XCTAssertEqual(briefing.sections[0].articles[0].body, body)
        XCTAssertEqual(briefing.sections[0].articles[0].image?.url, "not a url", "image URL problems are per-image outcomes")
        XCTAssertEqual(briefing.sections[1].articles.map(\.headline), ["Second", "Third"])

        let encoded = try JSONEncoder().encode(input)
        XCTAssertEqual(try RichPresentationValidator.validateInput(data: encoded), input)
    }

    func testBarChartAcceptsUniqueCategoriesAndRejectsDuplicates() throws {
        XCTAssertNoThrow(try validate(barChart(x: ["b", "a", "c"])))
        assertRejects(barChart(x: ["a", "b", "a"]), field: "content.x[2]", code: .duplicate)
    }

    // MARK: Version, structure and unknown fields

    func testRejectsUnsupportedOrMistypedVersion() {
        var input = lineChart()
        input["version"] = 2
        assertRejects(input, field: "version", code: .unsupportedVersion)
        input["version"] = "1"
        assertRejects(input, field: "version", code: .wrongType)
        input.removeValue(forKey: "version")
        assertRejects(input, field: "version", code: .missingField)
    }

    func testRejectsUnknownFieldsAtEveryLevel() {
        var top = lineChart()
        top["extra"] = true
        assertRejects(top, field: "extra", code: .unknownField)
        assertRejects(lineChart(extra: ["style": "fancy"]), field: "content.style", code: .unknownField)
        assertRejects(lineChart(series: [["name": "A", "y": [1, 2, 3], "color": "red"]]), field: "content.series[0].color", code: .unknownField)
        assertRejects(withContent(lineChart()) { $0["sources"] = [["label": "L", "title": "x"]] }, field: "content.sources[0].title", code: .unknownField)
        assertRejects(briefing(extra: ["html": "<p>"]), field: "content.html", code: .unknownField)
        assertRejects(briefing(sections: [["heading": "H", "articles": [article()], "id": 1]]), field: "content.sections[0].id", code: .unknownField)
        assertRejects(briefing(sections: [["heading": "H", "articles": [article(extra: ["chart": [:]])]]]), field: "content.sections[0].articles[0].chart", code: .unknownField)
        assertRejects(
            briefing(sections: [["heading": "H", "articles": [article(image: ["url": "https://a.example.com/i.png", "alt": "A", "width": 3])]]]),
            field: "content.sections[0].articles[0].image.width",
            code: .unknownField
        )
    }

    func testRejectsMalformedJSONTypesAndOversizedInput() {
        XCTAssertThrowsError(try RichPresentationValidator.validateInput(data: Data("{\"version\":1".utf8))) { error in
            XCTAssertEqual((error as? RichPresentationValidationError)?.code, .invalidJSON)
        }
        XCTAssertThrowsError(try RichPresentationValidator.validateInput(data: Data("[1e400]".utf8))) { error in
            XCTAssertEqual((error as? RichPresentationValidationError)?.code, .invalidJSON)
        }
        assertRejects([1, 2], field: "input", code: .wrongType)
        assertRejects(withContent(lineChart()) { $0["kind"] = "table" }, field: "content.kind", code: .invalidValue)
        var mistyped = lineChart()
        mistyped["title"] = 7
        assertRejects(mistyped, field: "title", code: .wrongType)

        let huge = String(repeating: "a", count: RichPresentationLimits.maxSerializedInputBytes)
        var oversized = lineChart()
        oversized["title"] = huge
        assertRejects(oversized, field: "input", code: .tooLarge)
    }

    func testOptionalFieldsMustBeOmittedNotNull() {
        assertRejects(briefing(extra: ["deck": NSNull()]), field: "content.deck", code: .wrongType)
        assertRejects(withContent(lineChart()) { $0["sources"] = [["label": "L", "url": NSNull()]] }, field: "content.sources[0].url", code: .wrongType)
    }

    // MARK: Text and count limits

    func testTextLimitsAreExactAndNeverTruncate() throws {
        var input = lineChart()
        input["title"] = String(repeating: "t", count: 160)
        XCTAssertNoThrow(try validate(input))
        input["title"] = String(repeating: "t", count: 161)
        assertRejects(input, field: "title", code: .tooLong)
        input["title"] = " \n\t"
        assertRejects(input, field: "title", code: .empty)

        assertRejects(withContent(lineChart()) { $0["unit"] = String(repeating: "u", count: 121) }, field: "content.unit", code: .tooLong)
        assertRejects(briefing(extra: ["deck": String(repeating: "d", count: 1201)]), field: "content.deck", code: .tooLong)
        assertRejects(briefing(sections: [["heading": "H", "articles": [article(body: String(repeating: "b", count: 12001))]]]), field: "content.sections[0].articles[0].body", code: .tooLong)
        assertRejects(briefing(sections: [["heading": "H", "articles": [article(headline: "")]]]), field: "content.sections[0].articles[0].headline", code: .empty)
        assertRejects(briefing(sections: [["heading": " ", "articles": [article()]]]), field: "content.sections[0].heading", code: .empty)
        assertRejects(
            briefing(sections: [["heading": "H", "articles": [article(image: ["url": "https://a.example.com/i", "alt": String(repeating: "a", count: 241)])]]]),
            field: "content.sections[0].articles[0].image.alt",
            code: .tooLong
        )
        assertRejects(
            briefing(sections: [["heading": "H", "articles": [article(image: ["url": "https://a.example.com/" + String(repeating: "p", count: 2048), "alt": "A"])]]]),
            field: "content.sections[0].articles[0].image.url",
            code: .tooLong
        )
    }

    func testSourceCountsAndURLRules() {
        assertRejects(withContent(lineChart()) { $0["sources"] = [] }, field: "content.sources", code: .tooFew)
        assertRejects(withContent(lineChart()) { $0["sources"] = Array(repeating: ["label": "L"], count: 5) }, field: "content.sources", code: .tooMany)
        assertRejects(withContent(lineChart()) { $0["sources"] = [["label": ""]] }, field: "content.sources[0].label", code: .empty)
        for bad in ["http://example.com/a", "https://user:pw@example.com/", "https://@example.com", "ftp://example.com", "https:///path", "https://exa mple.com", "https://example.com\\@evil.com/"] {
            assertRejects(withContent(lineChart()) { $0["sources"] = [["label": "L", "url": bad]] }, field: "content.sources[0].url", code: .invalidValue)
        }
        XCTAssertNoThrow(try validate(withContent(lineChart()) { $0["sources"] = [["label": "L", "url": "HTTPS://Example.com:8443/p?q=1#f"]] }))
    }

    func testBriefingSectionArticleAndImageCounts() {
        assertRejects(briefing(sections: []), field: "content.sections", code: .tooFew)
        assertRejects(briefing(sections: Array(repeating: ["heading": "H", "articles": [article()]], count: 7)), field: "content.sections", code: .tooMany)
        assertRejects(briefing(sections: [["heading": "H", "articles": []]]), field: "content.sections[0].articles", code: .tooFew)

        let six = Array(repeating: article(), count: 6)
        XCTAssertNoThrow(try validate(briefing(sections: [["heading": "A", "articles": six], ["heading": "B", "articles": six]])))
        assertRejects(
            briefing(sections: [["heading": "A", "articles": six], ["heading": "B", "articles": six + [article()]]]),
            field: "content.sections[1].articles[6]",
            code: .tooMany
        )

        let imaged = article(image: ["url": "https://img.example.com/x.jpg", "alt": "Alt", "credit": "Photo"])
        XCTAssertNoThrow(try validate(briefing(sections: [["heading": "A", "articles": Array(repeating: imaged, count: 4)]])))
        assertRejects(
            briefing(sections: [["heading": "A", "articles": Array(repeating: imaged, count: 3)], ["heading": "B", "articles": [article(), imaged, imaged]]]),
            field: "content.sections[1].articles[2].image",
            code: .tooMany
        )
    }

    // MARK: Chart data

    func testSeriesRules() {
        assertRejects(lineChart(series: []), field: "content.series", code: .tooFew)
        assertRejects(lineChart(series: (0 ..< 5).map { index -> [String: Any] in ["name": "S\(index)", "y": [1, 2, 3]] }), field: "content.series", code: .tooMany)
        assertRejects(lineChart(series: [["name": "A", "y": [1, 2, 3]], ["name": "A", "y": [1, 2, 3]]]), field: "content.series[1].name", code: .duplicate)
        assertRejects(lineChart(series: [["name": "A", "y": [1, 2]]]), field: "content.series[0].y", code: .lengthMismatch)
        assertRejects(lineChart(series: [["name": "A", "y": [NSNull(), NSNull(), NSNull()]]]), field: "content.series[0].y", code: .invalidValue)
        assertRejects(lineChart(series: [["name": "A", "y": [1, true, 3]]]), field: "content.series[0].y[1]", code: .wrongType)
        assertRejects(lineChart(series: [["name": "A", "y": [1, "2", 3]]]), field: "content.series[0].y[1]", code: .wrongType)
        assertRejects(lineChart(series: [["name": "", "y": [1, 2, 3]]]), field: "content.series[0].name", code: .empty)
    }

    func testXValueCountLimit() throws {
        let categories = (0 ..< 512).map { "c\($0)" }
        XCTAssertNoThrow(try validate(barChart(x: categories)))
        assertRejects(barChart(x: categories + ["c512"]), field: "content.x", code: .tooMany)
        assertRejects(barChart(x: []), field: "content.x", code: .tooFew)
    }

    func testLineTimestampsRequireRealStrictlyIncreasingInstants() {
        let one: [[String: Any]] = [["name": "A", "y": [1, 2]]]
        // Lexically increasing, but 10:00+02:00 is 08:00Z, earlier than 09:00Z.
        assertRejects(lineChart(x: ["2026-01-01T09:00:00Z", "2026-01-01T10:00:00+02:00"], series: one), field: "content.x[1]", code: .notIncreasing)
        // Same instant expressed with different offsets.
        assertRejects(lineChart(x: ["2026-01-01T09:00:00Z", "2026-01-01T10:00:00+01:00"], series: one), field: "content.x[1]", code: .notIncreasing)
        // Lexically decreasing, but actually increasing instants.
        XCTAssertNoThrow(try validate(lineChart(x: ["2026-01-01T10:00:00+02:00", "2026-01-01T09:00:00Z"], series: one)))
        XCTAssertNoThrow(try validate(lineChart(x: ["2026-01-01T09:00:00.000000001Z", "2026-01-01T09:00:00.000000002Z"], series: one)))

        for bad in ["2026-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-04-31T00:00:00Z", "2026-01-01T24:00:00Z", "2026-01-01T00:00:60Z", "2026-01-01T00:00:00", "2026-01-01 00:00:00Z", "2026-01-01T00:00:00.Z", "2026-01-01T00:00:00.1234567890Z", "2026-01-01T00:00:00+0100", "2026-01-01"] {
            assertRejects(lineChart(x: [bad, "2027-01-01T00:00:00Z"], series: one), field: "content.x[0]", code: .invalidValue)
        }
    }

    func testRFC3339InstantValues() throws {
        XCTAssertEqual(RichPresentationDateParser.instant(rfc3339: "1970-01-01T00:00:00Z"), RichPresentationInstant(secondsSince1970: 0, nanoseconds: 0))
        let instant = try XCTUnwrap(RichPresentationDateParser.instant(rfc3339: "2024-02-29T13:30:00.5+01:30"))
        XCTAssertEqual(instant.secondsSince1970, 1_709_208_000)
        XCTAssertEqual(instant.nanoseconds, 500_000_000)
        XCTAssertEqual(instant.date.timeIntervalSince1970, 1_709_208_000.5, accuracy: 0.000_001)
        XCTAssertEqual(RichPresentationDateParser.instant(rfc3339: "1969-12-31T23:59:59-00:00")?.secondsSince1970, -1)
    }

    func testBriefingDateMustBeRealCalendarDate() {
        XCTAssertTrue(RichPresentationDateParser.isValidCalendarDate("2000-02-29"))
        XCTAssertFalse(RichPresentationDateParser.isValidCalendarDate("1900-02-29"))
        for bad in ["2026-02-29", "2026-00-10", "2026-06-31", "2026-6-01", "20260601", "2026-06-01T00:00:00Z"] {
            assertRejects(briefing(extra: ["date": bad]), field: "content.date", code: .invalidValue)
        }
    }

    // MARK: Approved hosts and image URLs

    func testApprovedHostValidation() {
        XCTAssertEqual(try RichPresentationURLPolicy.validateApprovedHost("images.example.com").get(), "images.example.com")
        XCTAssertEqual(try RichPresentationURLPolicy.normalizeApprovedHostInput("  CDN.Example.COM \n").get(), "cdn.example.com")
        let cases: [(String, RichPresentationHostRejection)] = [
            ("", .empty),
            ("*.example.com", .wildcard),
            ("192.168.1.1", .ipLiteral),
            ("[::1]", .ipLiteral),
            ("::1", .ipLiteral),
            ("localhost", .localName),
            ("api.localhost", .localName),
            ("printer.local", .localName),
            ("intranet", .singleLabel),
            ("Example.com", .notLowercaseASCII),
            ("example.com.", .invalidSyntax),
            ("example..com", .invalidSyntax),
            ("-bad.example.com", .invalidSyntax),
            ("example.com:443", .invalidSyntax),
            ("user@example.com", .invalidSyntax),
            ("exämple.com", .invalidSyntax),
            ("1.2.3.0x4", .invalidSyntax),
            (String(repeating: "a", count: 64) + ".com", .invalidSyntax),
            (String(repeating: "a.", count: 127) + "com", .tooLong)
        ]
        for (host, expected) in cases {
            XCTAssertEqual(RichPresentationURLPolicy.validateApprovedHost(host), .failure(expected), host)
        }
    }

    func testImageURLEvaluationRequiresExactApprovedHost() {
        let approved: Set = ["img.example.com"]
        func evaluate(_ url: String) -> Result<URL, RichPresentationImageFailureCode> {
            RichPresentationURLPolicy.evaluateImageURL(url, approvedHosts: approved)
        }
        XCTAssertEqual(try evaluate("https://img.example.com/a.jpg?sig=abc").get().absoluteString, "https://img.example.com/a.jpg?sig=abc")
        XCTAssertNoThrow(try evaluate("https://IMG.Example.com:443/a.jpg").get())
        XCTAssertEqual(evaluate("https://cdn.img.example.com/a.jpg"), .failure(.hostNotApproved))
        XCTAssertEqual(evaluate("https://example.com/a.jpg"), .failure(.hostNotApproved))
        for bad in ["http://img.example.com/a.jpg", "https://img.example.com:8443/a.jpg", "https://u@img.example.com/a.jpg", "https://127.0.0.1/a.jpg", "https://[::1]/a.jpg", "https://localhost/a.jpg", "https://img.example.com./a.jpg", "https://img.example.com\\@evil.com/", "not a url", ""] {
            XCTAssertEqual(evaluate(bad), .failure(.invalidURL), bad)
        }
    }

    // MARK: Reference and result

    func testReferenceRoundTripsStrictly() throws {
        let reference = RichPresentationReference(
            artifactID: UUID(),
            kind: .briefing,
            title: "Morning briefing",
            fallbackText: "[Briefing summary] Two sections.",
            warnings: [RichPresentationWarning(sectionIndex: 1, articleIndex: 0, code: .hostNotApproved)]
        )
        let encoded = try JSONEncoder().encode(RichPresentationResult(presentation: reference))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let presentation = try XCTUnwrap(object["presentation"] as? [String: Any])
        XCTAssertEqual(Set(presentation.keys), ["version", "artifact_id", "kind", "title", "fallback_text", "warnings"])
        XCTAssertEqual(try RichPresentationValidator.decodeResult(data: encoded).presentation, reference)
        XCTAssertEqual(try JSONDecoder().decode(RichPresentationResult.self, from: encoded).presentation, reference)
    }

    func testReferenceRejectsUnknownFieldsBadValuesAndOversizedFallback() throws {
        let base: [String: Any] = [
            "version": 1,
            "artifact_id": UUID().uuidString,
            "kind": "chart",
            "title": "T",
            "fallback_text": "Summary",
            "warnings": []
        ]
        XCTAssertNoThrow(try RichPresentationValidator.decodeReference(data: data(base)))

        func rejects(_ mutate: (inout [String: Any]) -> Void, field: String, code: RichPresentationValidationError.Code) throws {
            var value = base
            mutate(&value)
            XCTAssertThrowsError(try RichPresentationValidator.decodeReference(data: data(value))) { error in
                let failure = error as? RichPresentationValidationError
                XCTAssertEqual(failure?.field, field)
                XCTAssertEqual(failure?.code, code)
            }
        }
        try rejects({ $0["path"] = "/tmp/x" }, field: "path", code: .unknownField)
        try rejects({ $0["version"] = 2 }, field: "version", code: .unsupportedVersion)
        try rejects({ $0["artifact_id"] = "nope" }, field: "artifact_id", code: .invalidValue)
        try rejects({ $0["fallback_text"] = String(repeating: "é", count: 1025) }, field: "fallback_text", code: .tooLong)
        try rejects({ $0["warnings"] = [["section_index": 0, "article_index": 0, "code": "deadline"]] }, field: "warnings", code: .invalidValue)
        try rejects({
            $0["kind"] = "briefing"
            $0["warnings"] = [["section_index": 0, "article_index": 0.5, "code": "deadline"]]
        }, field: "warnings[0].article_index", code: .invalidValue)
        try rejects({
            $0["kind"] = "briefing"
            $0["warnings"] = [["section_index": 0, "article_index": 0, "code": "boom"]]
        }, field: "warnings[0].code", code: .invalidValue)
        XCTAssertThrowsError(try RichPresentationValidator.decodeResult(data: data(["presentation": base, "extra": 1])))
    }
}
