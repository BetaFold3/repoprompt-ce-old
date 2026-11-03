import Foundation
@testable import RepoPromptClaudeCompatibleProvider
import XCTest

final class ClaudeSDKProtocolCodecTests: XCTestCase {
    /// Long decimal literals reach the codec as `NSDecimalNumber` from `JSONSerialization`, whose
    /// `doubleValue` is not the nearest double (captured 2.1.268 cumulative cost
    /// `0.007236599999999999` came back as `…996`). The DTO must hold the correctly rounded
    /// double, whose shortest round-trip text is the wire lexeme again, so cumulative cost keeps
    /// wire precision downstream. Short literals keep their prior exact behaviour.
    func testDecodeLineParsesLongDecimalLiteralsToTheNearestDoubleOfTheWireLexeme() throws {
        let wireLine = Data(#"{"type":"result","uuid":"env-precise","total_cost_usd":0.007236599999999999,"short":0.0051568,"modelUsage":{"m":{"costUSD":0.0062916}}}"#.utf8)
        guard case let .streamPayload(payload)? = try ClaudeSDKProtocolCodec.decodeLine(wireLine) else {
            XCTFail("Expected stream payload")
            return
        }
        guard case let .double(precise)? = payload["total_cost_usd"] else {
            return XCTFail("expected a double, got \(String(describing: payload["total_cost_usd"]))")
        }
        let nearestDouble = try XCTUnwrap(Double("0.007236599999999999"))
        XCTAssertEqual(String(precise), "0.007236599999999999", "shortest round-trip text must equal the wire lexeme")
        XCTAssertEqual(precise, nearestDouble)
        XCTAssertEqual(payload["short"], .double(0.0051568))
        XCTAssertEqual(payload["modelUsage"]?.objectValue?["m"]?.objectValue?["costUSD"], .double(0.0062916))
        // The decoder shape itself: a long literal is an `NSDecimalNumber` whose `doubleValue` is
        // imprecise, which is exactly what the DTO conversion must not propagate.
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"c":0.007236599999999999}"#.utf8)) as? [String: Any])
        let number = try XCTUnwrap(raw["c"] as? NSNumber)
        if number is NSDecimalNumber {
            XCTAssertNotEqual(String(number.doubleValue), "0.007236599999999999", "if this ever holds, the special case is no longer needed")
        }
        let converted = try ClaudeProviderJSONValue(any: number)
        XCTAssertEqual(converted, .double(nearestDouble))
    }

    /// Production path: wire bytes → `decodeLine` → DTO → `parseStreamPayload`. JSON `0`/`1`
    /// must stay numeric (a reported zero is observed as zero, never missing) while real JSON
    /// booleans stay boolean. Regression for the `NSNumber(0|1)`→`Bool` bridging defect.
    func testDecodeLineKeepsNumericZeroAndOneDistinctFromBooleansThroughTranslator() throws {
        let wireLine = Data(#"{"type":"result","subtype":"success","is_error":false,"uuid":"env-wire","session_id":"s-wire","num_turns":1,"result_index":0,"queued_turn_count":0,"total_cost_usd":0.076465,"usage":{"input_tokens":2,"output_tokens":1,"cache_read_input_tokens":48780,"cache_creation_input_tokens":0},"modelUsage":{"m":{"cacheReadInputTokens":0,"costUSD":1}}}"#.utf8)

        guard case let .streamPayload(payload)? = try ClaudeSDKProtocolCodec.decodeLine(wireLine) else {
            XCTFail("Expected stream payload")
            return
        }
        XCTAssertEqual(payload["num_turns"], .integer(1))
        XCTAssertEqual(payload["result_index"], .integer(0))
        XCTAssertEqual(payload["queued_turn_count"], .integer(0))
        XCTAssertEqual(payload["is_error"], .bool(false))
        XCTAssertEqual(payload["total_cost_usd"], .double(0.076465))
        let usage = try XCTUnwrap(payload["usage"]?.objectValue)
        XCTAssertEqual(usage["output_tokens"], .integer(1))
        XCTAssertEqual(usage["cache_creation_input_tokens"], .integer(0))
        let modelUsage = try XCTUnwrap(payload["modelUsage"]?.objectValue?["m"]?.objectValue)
        XCTAssertEqual(modelUsage["cacheReadInputTokens"], .integer(0))
        XCTAssertEqual(modelUsage["costUSD"], .integer(1))

        // Direct value-level contract for every `JSONSerialization` shape the codec can receive.
        let serialized = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"t":true,"f":false,"one":1,"zero":0,"neg":-1,"big":1e20,"frac":0.5,"three":3.0,"sci":1e18,"sciFrac":1.5e18}"#.utf8)) as? [String: Any]
        )
        let expectedByKey: [(key: String, value: ClaudeProviderJSONValue)] = [
            ("t", .bool(true)), ("f", .bool(false)), ("one", .integer(1)), ("zero", .integer(0)),
            ("neg", .integer(-1)), ("big", .double(1e20)), ("frac", .double(0.5)), ("three", .integer(3)),
            // Scientific-notation integral doubles within `Int` range stay `.integer` (`stringValue`
            // is "1e+18", so this exercises the restored `Int(exactly:)` normalization).
            ("sci", .integer(1_000_000_000_000_000_000)), ("sciFrac", .integer(1_500_000_000_000_000_000))
        ]
        for (key, expected) in expectedByKey {
            let raw = try XCTUnwrap(serialized[key], key)
            let decoded = try ClaudeProviderJSONValue(any: raw)
            XCTAssertEqual(decoded, expected, key)
        }
        // Native Swift inputs keep their prior behaviour.
        let nativeBool = try ClaudeProviderJSONValue(any: true)
        XCTAssertEqual(nativeBool, .bool(true))
        let nativeZero = try ClaudeProviderJSONValue(any: 0)
        XCTAssertEqual(nativeZero, .integer(0))
        let nativeIntegralDouble = try ClaudeProviderJSONValue(any: 2.0)
        XCTAssertEqual(nativeIntegralDouble, .integer(2))
        let nativeLargeIntegralDouble = try ClaudeProviderJSONValue(any: Double(1e18))
        XCTAssertEqual(nativeLargeIntegralDouble, .integer(1_000_000_000_000_000_000))
        let nativeOutOfRangeDouble = try ClaudeProviderJSONValue(any: Double(1e20))
        XCTAssertEqual(nativeOutOfRangeDouble, .double(1e20))
        XCTAssertThrowsError(try ClaudeProviderJSONValue(any: Double.nan))
        XCTAssertThrowsError(try ClaudeProviderJSONValue(any: Double.infinity))

        // Wire path for the same large integral double and for a JSON boolean in a count field:
        // the boolean must stay boolean in the DTO and become a *missing* count (not 1, not 0)
        // after `foundationObject()` reaches the translator.
        let edgeLine = Data(#"{"type":"assistant","uuid":"env-edge","request_id":"req-edge","message":{"id":"msg_edge","usage":{"input_tokens":1e18,"output_tokens":true,"cache_read_input_tokens":0,"cache_creation_input_tokens":false}}}"#.utf8)
        guard case let .streamPayload(edgePayload)? = try ClaudeSDKProtocolCodec.decodeLine(edgeLine) else {
            XCTFail("Expected stream payload")
            return
        }
        let edgeUsage = try XCTUnwrap(edgePayload["message"]?.objectValue?["usage"]?.objectValue)
        XCTAssertEqual(edgeUsage["input_tokens"], .integer(1_000_000_000_000_000_000))
        XCTAssertEqual(edgeUsage["output_tokens"], .bool(true))
        XCTAssertEqual(edgeUsage["cache_creation_input_tokens"], .bool(false))
        var edgeTranslator = ClaudeSDKNDJSONTranslator()
        let edgeUsageResult = try XCTUnwrap(edgeTranslator.parseStreamPayload(edgePayload).first { $0.type == "usage" })
        let edgeObservation = try XCTUnwrap(edgeUsageResult.usageObservation)
        XCTAssertEqual(edgeObservation.inputTokens, 1_000_000_000_000_000_000, "large integral double is an exact count")
        XCTAssertNil(edgeObservation.outputTokens, "wire boolean count stays missing, never 1")
        XCTAssertEqual(edgeObservation.cacheReadInputTokens, 0)
        XCTAssertNil(edgeObservation.cacheCreationInputTokens, "wire boolean count stays missing, never 0")
        // Legacy prompt/completion/context normalization for boolean inputs is owned by the
        // translator table test (`ClaudeSDKNDJSONTranslatorTests`), not asserted here.

        var translator = ClaudeSDKNDJSONTranslator()
        let results = translator.parseStreamPayload(payload)
        let stop = try XCTUnwrap(results.first { $0.type == "message_stop" })
        let observation = try XCTUnwrap(stop.usageObservation)
        XCTAssertEqual(observation.source, .result)
        XCTAssertEqual(observation.inputTokens, 2)
        XCTAssertEqual(observation.outputTokens, 1, "wire 1 stays an observed count")
        XCTAssertEqual(observation.cacheReadInputTokens, 48780)
        XCTAssertEqual(observation.cacheCreationInputTokens, 0, "wire 0 is an observed zero, not missing")
        XCTAssertEqual(observation.resultIsError, false, "real JSON boolean stays boolean")
        XCTAssertEqual(observation.envelopeID, "env-wire")
        XCTAssertEqual(stop.cost, 0.076465)
        XCTAssertEqual(stop.promptTokens, 2)
        XCTAssertEqual(stop.completionTokens, 1)
    }

    func testProtocolCodecSmokeDecodesControlRepairsControlCharactersAndEncodesUserMessage() throws {
        let controlLine = Data(#"{"type":"control_request","request_id":"req-1","request":{"subtype":"permission","tool_name":"read_file","input":{"path":"Sources/App.swift"}}}"#.utf8)

        let controlMessage = try ClaudeSDKProtocolCodec.decodeLine(controlLine)

        guard case let .controlRequest(request) = controlMessage else {
            XCTFail("Expected control request")
            return
        }
        XCTAssertEqual(request.requestID, "req-1")
        XCTAssertEqual(request.subtype, "permission")
        XCTAssertEqual(request.request["tool_name"], .string("read_file"))
        XCTAssertEqual(request.request["input"]?.objectValue?["path"], .string("Sources/App.swift"))

        let rawControlCharacterLine = Data("{\"type\":\"assistant\",\"message\":{\"content\":\"hello\nworld\"}}".utf8)
        let streamMessage = try ClaudeSDKProtocolCodec.decodeLine(rawControlCharacterLine)
        guard case let .streamPayload(payload) = streamMessage else {
            XCTFail("Expected stream payload")
            return
        }
        XCTAssertEqual(payload["type"], .string("assistant"))
        XCTAssertEqual(payload["message"]?.objectValue?["content"], .string("hello\nworld"))

        let userData = try ClaudeSDKProtocolCodec.encodeUserMessage(text: "Continue", sessionID: "session-1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: userData) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        XCTAssertEqual(object["session_id"] as? String, "session-1")
        XCTAssertTrue(object["parent_tool_use_id"] is NSNull)
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
    }

    func testUserMessageOutboundUUIDIsOptionalTopLevelAndLowercase() throws {
        let legacy = try ClaudeSDKProtocolCodec.encodeUserMessage(text: "Continue", sessionID: "session-1")
        let explicitNil = try ClaudeSDKProtocolCodec.encodeUserMessage(text: "Continue", sessionID: "session-1", messageUUID: nil)
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        let nilObject = try XCTUnwrap(JSONSerialization.jsonObject(with: explicitNil) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: nilObject), NSDictionary(dictionary: legacyObject), "no UUID keeps the legacy frame")
        XCTAssertEqual(Set(legacyObject.keys), ["type", "message", "parent_tool_use_id", "session_id"])
        XCTAssertNil(legacyObject["uuid"])

        let uuid = try XCTUnwrap(UUID(uuidString: "A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF"))
        let withUUID = try ClaudeSDKProtocolCodec.encodeUserMessage(text: "Continue", sessionID: "session-1", messageUUID: uuid)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: withUUID) as? [String: Any])
        XCTAssertEqual(object["uuid"] as? String, "a1b2c3d4-e5f6-4711-8899-aabbccddeeff")
        var withoutUUID = object
        withoutUUID.removeValue(forKey: "uuid")
        XCTAssertEqual(NSDictionary(dictionary: withoutUUID), NSDictionary(dictionary: legacyObject), "only the top-level uuid is added")
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        XCTAssertNil(message["uuid"])
    }
}
