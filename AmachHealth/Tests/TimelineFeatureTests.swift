import XCTest
@testable import AmachHealth

final class TimelineEventTypeTests: XCTestCase {
    func test_medication_started_has_required_name_field() {
        let fields = TimelineEventType.medicationStarted.fields
        XCTAssertTrue(fields.contains { $0.key == "name" && $0.required })
    }

    func test_general_note_requires_note_body() {
        let fields = TimelineEventType.generalNote.fields
        XCTAssertTrue(fields.contains { $0.key == "notes" && $0.required })
    }
}

final class TimelineEventTests: XCTestCase {
    func test_health_event_maps_to_auto_detected_timeline_event() {
        let event = HealthEvent(
            metricType: "heartRateVariabilitySDNN",
            anomalyType: .deviation,
            direction: .declining,
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            baselineValue: 52,
            peakDeviation: 38,
            deviationPct: -27,
            durationDays: 3
        )

        let timelineEvent = TimelineEvent(fromHealthEvent: event)

        XCTAssertEqual(timelineEvent.metadata.source, .autoDetected)
        XCTAssertEqual(timelineEvent.metricType, "heartRateVariabilitySDNN")
        XCTAssertEqual(timelineEvent.deviationPct, -27)
        XCTAssertTrue(timelineEvent.isAnomaly)
    }

    func test_timeline_event_roundtrip_codable() throws {
        let event = TimelineEvent(
            id: "evt_1",
            eventType: .lifestyleChange,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            data: ["change": "Started zone 2 training"],
            metadata: TimelineEventMetadata(platform: "ios", version: "1", source: .userEntered),
            anomalyType: nil,
            metricType: nil,
            direction: nil,
            deviationPct: nil,
            resolvedAt: nil,
            attestationTxHash: "0xabc"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(event)
        let decoded = try decoder.decode(TimelineEvent.self, from: data)

        XCTAssertEqual(decoded.id, event.id)
        XCTAssertEqual(decoded.attestationTxHash, "0xabc")
    }
}

final class LabRecordTests: XCTestCase {
    func test_lab_record_title_matches_type() {
        XCTAssertEqual(
            LabRecord(id: "1", date: .now, type: "bloodwork", values: [:], units: [:], notes: nil, attestationTxHash: nil).title,
            "Bloodwork"
        )
        XCTAssertEqual(
            LabRecord(id: "2", date: .now, type: "dexa", values: [:], units: [:], notes: nil, attestationTxHash: nil).title,
            "DEXA Scan"
        )
    }
}

final class AIChatContextWalletTests: XCTestCase {
    func test_ai_chat_context_encodes_user_address() throws {
        let context = AIChatContext(
            metrics: nil,
            dateRange: nil,
            proactive: nil,
            memory: nil,
            userAddress: "0xabc"
        )

        let data = try JSONEncoder().encode(context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["userAddress"] as? String, "0xabc")
    }
}

final class StorjListItemAttestationTests: XCTestCase {
    func test_reads_attestation_hash_from_metadata() {
        let item = StorjListItem(
            uri: "storj://record",
            contentHash: "sha256:test",
            size: 12,
            uploadedAt: 1_700_000_000_000,
            dataType: "bloodwork",
            metadata: ["attestationTxHash": "0xtx"]
        )

        XCTAssertEqual(item.attestationTxHash, "0xtx")
    }
}

final class CreateAttestationResponseTests: XCTestCase {
    func test_decodes_attestation_response() throws {
        let json = """
        {
          "success": true,
          "attestation": {
            "txHash": "0x123",
            "attestationUID": "0x456",
            "blockNumber": 42
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CreateAttestationResponse.self, from: json)
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.attestation?.txHash, "0x123")
        XCTAssertEqual(response.attestation?.blockNumber, 42)
    }
}

final class TimelineEventWebFormatTests: XCTestCase {
    /// Web stores timestamp as Unix ms and metadata as { source, confidence, tags }
    func test_decodes_web_stored_event() throws {
        let json = """
        {
          "id": "web-evt-1",
          "eventType": "MEDICATION_STARTED",
          "timestamp": 1709510400000,
          "data": { "name": "Metformin", "dosage": "500mg" },
          "metadata": { "source": "user-input", "confidence": 1.0 }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(TimelineEvent.self, from: json)

        XCTAssertEqual(event.id, "web-evt-1")
        XCTAssertEqual(event.eventType, .medicationStarted)
        XCTAssertEqual(event.data["name"], "Metformin")
        XCTAssertEqual(event.metadata.source, .userEntered)
        // Unix ms 1709510400000 = 2024-03-04T00:00:00Z
        XCTAssertEqual(event.timestamp.timeIntervalSince1970, 1_709_510_400, accuracy: 1)
    }

    /// Unknown web event types should decode as .custom
    func test_unknown_event_type_falls_back_to_custom() throws {
        let json = """
        {
          "id": "web-evt-2",
          "eventType": "SOME_FUTURE_TYPE",
          "timestamp": 1709510400000,
          "data": {},
          "metadata": { "source": "user-input" }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(TimelineEvent.self, from: json)
        XCTAssertEqual(event.eventType, .custom)
    }

    /// Web data values can be non-string (numbers, booleans)
    func test_decodes_mixed_data_values() throws {
        let json = """
        {
          "id": "web-evt-3",
          "eventType": "WEIGHT_RECORDED",
          "timestamp": 1709510400000,
          "data": { "weight": 165, "unit": "lbs", "fasting": true },
          "metadata": { "source": "user-input" }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(TimelineEvent.self, from: json)
        XCTAssertEqual(event.data["weight"], "165")
        XCTAssertEqual(event.data["unit"], "lbs")
        XCTAssertEqual(event.data["fasting"], "true")
    }
}

final class TimelineEventCollectionTests: XCTestCase {
    func test_decodes_raw_array_shape() throws {
        let json = """
        [
          {
            "id": "evt_1",
            "eventType": "GENERAL_NOTE",
            "timestamp": "2026-03-01T10:00:00Z",
            "data": { "notes": "Started new protocol" },
            "metadata": { "platform": "web", "version": "1", "source": "user" }
          }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let collection = try decoder.decode(TimelineEventCollection.self, from: json)

        XCTAssertEqual(collection.events.count, 1)
        XCTAssertEqual(collection.events.first?.id, "evt_1")
    }

    func test_decodes_wrapped_events_shape() throws {
        let json = """
        {
          "events": [
            {
              "id": "evt_2",
              "eventType": "LIFESTYLE_CHANGE",
              "timestamp": "2026-03-01T10:00:00Z",
              "data": { "change": "Started zone 2" },
              "metadata": { "platform": "web", "version": "1", "source": "user" }
            }
          ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let collection = try decoder.decode(TimelineEventCollection.self, from: json)

        XCTAssertEqual(collection.events.count, 1)
        XCTAssertEqual(collection.events.first?.eventType, .lifestyleChange)
    }
}
