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
    func test_ai_chat_context_encodes_wallet_credentials() throws {
        let context = AIChatContext(
            metrics: nil,
            dateRange: nil,
            proactive: nil,
            memory: nil,
            userAddress: "0xabc",
            encryptionKey: WalletEncryptionKey(
                walletAddress: "0xabc",
                encryptionKey: "deadbeef",
                signature: "0xsig",
                timestamp: 123
            )
        )

        let data = try JSONEncoder().encode(context)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["userAddress"] as? String, "0xabc")
        XCTAssertNotNil(json?["encryptionKey"] as? [String: Any])
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
