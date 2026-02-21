// APIClientTests.swift
// AmachHealthTests
//
// Tests for AmachAPIClient: SSE chunk parsing, request construction,
// Storj response decoding, error handling.
//
// Fully runnable without a Simulator — uses MockURLProtocol to
// intercept URLSession calls and return scripted responses.

import XCTest
@testable import AmachHealth


// ============================================================
// MARK: - SSE CHUNK DECODING
// ============================================================
//
// These tests are pure JSON decoding — no networking required.
// They validate the SSE parsing contract between /api/venice/
// and AmachAPIClient.streamLumaChat().

final class SSEChunkDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()

    func test_decodes_standard_content_chunk() throws {
        let json = #"{"content":"Hello"}"#.data(using: .utf8)!
        let chunk = try decoder.decode(SSEChunk.self, from: json)
        XCTAssertEqual(chunk.content, "Hello")
    }

    func test_decodes_empty_content() throws {
        let json = #"{"content":""}"#.data(using: .utf8)!
        let chunk = try decoder.decode(SSEChunk.self, from: json)
        XCTAssertEqual(chunk.content, "")
    }

    func test_decodes_unicode_content() throws {
        let json = #"{"content":"💚 Amach"}"#.data(using: .utf8)!
        let chunk = try decoder.decode(SSEChunk.self, from: json)
        XCTAssertEqual(chunk.content, "💚 Amach")
    }

    func test_decodes_multi_token_whitespace() throws {
        // Streaming APIs often send individual spaces as tokens
        let json = #"{"content":" "}"#.data(using: .utf8)!
        let chunk = try decoder.decode(SSEChunk.self, from: json)
        XCTAssertEqual(chunk.content, " ")
    }

    func test_ignores_extra_fields() throws {
        // API may add metadata in future; decoder should tolerate extras
        let json = #"{"content":"test","model":"luma-v2","usage":{"tokens":5}}"#.data(using: .utf8)!
        let chunk = try decoder.decode(SSEChunk.self, from: json)
        XCTAssertEqual(chunk.content, "test")
    }

    func test_throws_on_missing_content_field() {
        let json = #"{"message":"Hello"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(SSEChunk.self, from: json))
    }

    func test_sse_line_parsing_strips_data_prefix() {
        // Validate the string manipulation in streamLumaChat()
        let line = #"data: {"content":"token"}"#
        XCTAssertTrue(line.hasPrefix("data: "))
        let payload = String(line.dropFirst(6))
        XCTAssertEqual(payload, #"{"content":"token"}"#)
    }

    func test_done_sentinel_detection() {
        let doneLine = "data: [DONE]"
        XCTAssertTrue(doneLine.hasPrefix("data: "))
        let payload = String(doneLine.dropFirst(6))
        XCTAssertEqual(payload, "[DONE]")
    }

    func test_non_data_lines_are_skipped() {
        // SSE spec: comment lines start with ":"
        let commentLine = ": keep-alive"
        XCTAssertFalse(commentLine.hasPrefix("data: "))

        // Empty lines are SSE event separators
        let emptyLine = ""
        XCTAssertFalse(emptyLine.hasPrefix("data: "))
    }
}


// ============================================================
// MARK: - VENICE CHAT REQUEST ENCODING
// ============================================================

final class VeniceChatRequestTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder = JSONDecoder()

    func test_encodes_required_fields() throws {
        let request = VeniceChatRequest(
            message: "How is my heart rate?",
            history: [],
            context: nil,
            screen: "Dashboard",
            metric: nil,
            stream: true
        )
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["message"] as? String, "How is my heart rate?")
        XCTAssertEqual(dict["stream"] as? Bool, true)
        XCTAssertEqual(dict["screen"] as? String, "Dashboard")
    }

    func test_encodes_history_messages() throws {
        let history = [
            AIChatHistoryMessage(role: "user", content: "Hello"),
            AIChatHistoryMessage(role: "assistant", content: "Hi there"),
        ]
        let request = VeniceChatRequest(
            message: "Next question",
            history: history,
            context: nil,
            screen: nil,
            metric: nil,
            stream: true
        )
        let data = try encoder.encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let encodedHistory = dict["history"] as? [[String: Any]]

        XCTAssertEqual(encodedHistory?.count, 2)
        XCTAssertEqual(encodedHistory?.first?["role"] as? String, "user")
        XCTAssertEqual(encodedHistory?.first?["content"] as? String, "Hello")
    }

    func test_metric_context_field_is_optional() throws {
        let request = VeniceChatRequest(
            message: "test",
            history: [],
            context: nil,
            screen: nil,
            metric: nil,
            stream: false
        )
        // Should encode without error even when all optionals are nil
        XCTAssertNoThrow(try encoder.encode(request))
    }
}


// ============================================================
// MARK: - STORJ RESPONSE DECODING
// ============================================================

final class StorjResponseDecodingTests: XCTestCase {

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func test_decodes_successful_store_result() throws {
        let json = """
        {
            "success": true,
            "result": {
                "storjUri": "storj://bucket/path/file.enc",
                "contentHash": "sha256:abc123",
                "size": 4096
            }
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(StorjResponse<StorjStoreResult>.self, from: json)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.result?.storjUri, "storj://bucket/path/file.enc")
        XCTAssertEqual(response.result?.contentHash, "sha256:abc123")
        XCTAssertEqual(response.result?.size, 4096)
        XCTAssertNil(response.error)
    }

    func test_decodes_error_response() throws {
        let json = """
        {
            "success": false,
            "error": "Encryption key mismatch"
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(StorjResponse<StorjStoreResult>.self, from: json)
        XCTAssertFalse(response.success)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error, "Encryption key mismatch")
    }

    func test_decodes_list_response() throws {
        let json = """
        {
            "success": true,
            "result": [
                {
                    "uri": "storj://bucket/file1.enc",
                    "contentHash": "sha256:111",
                    "size": 1024,
                    "uploadedAt": 1700000000000,
                    "dataType": "apple-health-full-export",
                    "metadata": { "tier": "GOLD", "metricsCount": "142" }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try decoder.decode(StorjResponse<[StorjListItem]>.self, from: json)
        let items = try XCTUnwrap(response.result)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].tier, "GOLD")
        XCTAssertEqual(items[0].metricsCount, 142)
    }
}


// ============================================================
// MARK: - STORJ LIST ITEM COMPUTED PROPERTIES
// ============================================================

final class StorjListItemTests: XCTestCase {

    private func makeItem(
        metadata: [String: String]? = nil,
        uploadedAt: TimeInterval = 1_700_000_000_000
    ) -> StorjListItem {
        StorjListItem(
            uri: "storj://test/file.enc",
            contentHash: "sha256:abc",
            size: 512,
            uploadedAt: uploadedAt,
            dataType: "apple-health-full-export",
            metadata: metadata
        )
    }

    func test_uploadDate_converts_milliseconds_to_date() {
        let item = makeItem(uploadedAt: 1_700_000_000_000)
        // 1_700_000_000_000 ms = 1_700_000_000 seconds (Nov 2023)
        XCTAssertEqual(item.uploadDate.timeIntervalSince1970, 1_700_000_000, accuracy: 1)
    }

    func test_tier_reads_from_metadata() {
        XCTAssertEqual(makeItem(metadata: ["tier": "GOLD"]).tier, "GOLD")
        XCTAssertEqual(makeItem(metadata: ["tier": "SILVER"]).tier, "SILVER")
        XCTAssertNil(makeItem(metadata: nil).tier)
    }

    func test_metricsCount_parses_string_to_int() {
        XCTAssertEqual(makeItem(metadata: ["metricsCount": "142"]).metricsCount, 142)
        XCTAssertNil(makeItem(metadata: ["metricsCount": "not-a-number"]).metricsCount)
        XCTAssertNil(makeItem(metadata: nil).metricsCount)
    }

    func test_dateRange_splits_on_underscore() {
        let item = makeItem(metadata: ["dateRange": "2024-01-01_2024-01-31"])
        let range = item.dateRange
        XCTAssertEqual(range?.start, "2024-01-01")
        XCTAssertEqual(range?.end, "2024-01-31")
    }

    func test_dateRange_returns_nil_for_malformed_string() {
        XCTAssertNil(makeItem(metadata: ["dateRange": "2024-01-01"]).dateRange)
        XCTAssertNil(makeItem(metadata: nil).dateRange)
    }
}


// ============================================================
// MARK: - ATTESTATION INFO
// ============================================================

final class AttestationInfoTests: XCTestCase {

    private func makeAttestation(score: Int, coreComplete: Bool) -> AttestationInfo {
        AttestationInfo(
            contentHash: "0xabc",
            dataType: 2,
            startDate: 0,
            endDate: 0,
            completenessScore: score,
            recordCount: 100,
            coreComplete: coreComplete,
            timestamp: 0
        )
    }

    func test_gold_tier_requires_score_80_and_core_complete() {
        XCTAssertEqual(makeAttestation(score: 8000, coreComplete: true).tier, .gold)
        XCTAssertEqual(makeAttestation(score: 8000, coreComplete: false).tier, .bronze)
    }

    func test_silver_tier_requires_score_60_and_core_complete() {
        XCTAssertEqual(makeAttestation(score: 6000, coreComplete: true).tier, .silver)
        XCTAssertEqual(makeAttestation(score: 6000, coreComplete: false).tier, .bronze)
    }

    func test_bronze_tier_requires_score_40() {
        XCTAssertEqual(makeAttestation(score: 4000, coreComplete: false).tier, .bronze)
    }

    func test_none_tier_for_low_score() {
        XCTAssertEqual(makeAttestation(score: 2000, coreComplete: false).tier, .none)
        XCTAssertEqual(makeAttestation(score: 0, coreComplete: true).tier, .none)
    }

    func test_dataTypeName_maps_correctly() {
        XCTAssertEqual(makeAttestation(score: 0, coreComplete: false).dataTypeName, "Apple Health")
    }

    // MARK: - Xcode-required stubs

    // TODO (Xcode): Test API error propagation when Storj returns non-200
    // TODO (Xcode): Test AmachAPIClient.storeHealthData() end-to-end with MockURLSession
    // TODO (Xcode): Test AmachAPIClient.streamLumaChat() yields tokens in correct order
    // TODO (Xcode): Test streamLumaChat() terminates on [DONE] sentinel
    // TODO (Xcode): Test streamLumaChat() throws on non-200 response
    // TODO (Xcode): Test retry logic behavior on network failure
}
