// StorjTimelineServiceTests.swift
// AmachHealthTests
//
// Unit tests for StorjTimelineService using a mock TimelineAPIProtocol.
// Covers: add, delete, fetch, syncAll, round-trip, conflict resolution,
// and empty-state initialisation.

import XCTest
@testable import AmachHealth

// MARK: - Mock API

/// In-memory implementation of TimelineAPIProtocol for unit testing.
/// All methods are synchronous-equivalent (no real network calls).
final class MockTimelineAPI: TimelineAPIProtocol {

    // In-memory store keyed by eventId
    private var store: [String: TimelineEvent] = [:]

    // Injected error overrides
    var storeError: Error?
    var listError: Error?
    var deleteError: Error?

    // Call tracking
    var storeCallCount = 0
    var listCallCount = 0
    var deleteCallCount = 0
    var lastStoredEvent: TimelineEvent?
    var lastDeletedId: String?

    // MARK: - TimelineAPIProtocol

    func storeTimelineEvent(
        event: TimelineEvent,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        storeCallCount += 1
        if let err = storeError { throw err }
        lastStoredEvent = event
        store[event.id] = event
        return StorjStoreResult(
            storjUri: "storj://mock-bucket/timeline/\(event.id).enc",
            contentHash: "sha256mock\(event.id)",
            size: 512
        )
    }

    func listTimelineEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [TimelineEvent] {
        listCallCount += 1
        if let err = listError { throw err }
        return store.values.sorted { $0.timestamp > $1.timestamp }
    }

    func deleteTimelineEvent(
        eventId: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws {
        deleteCallCount += 1
        if let err = deleteError { throw err }
        lastDeletedId = eventId
        store.removeValue(forKey: eventId)
    }
}

// MARK: - Fixtures

private extension TimelineEvent {
    static func fixture(
        id: String = UUID().uuidString,
        type: TimelineEventType = .lifestyleChange,
        timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000),
        data: [String: String] = ["change": "Started zone 2 training"]
    ) -> TimelineEvent {
        TimelineEvent(
            id: id,
            eventType: type,
            timestamp: timestamp,
            data: data,
            metadata: TimelineEventMetadata(platform: "ios", version: "1", source: .userEntered)
        )
    }
}

private extension WalletEncryptionKey {
    static var mock: WalletEncryptionKey {
        WalletEncryptionKey(
            walletAddress: "0xMock",
            encryptionKey: "mockaeskey",
            signature: "mocksig",
            timestamp: 0
        )
    }
}

// MARK: - StorjTimelineServiceTests

final class StorjTimelineServiceTests: XCTestCase {

    private var mockAPI: MockTimelineAPI!
    private var service: StorjTimelineService!
    private let wallet = "0xMock"
    private let key = WalletEncryptionKey.mock

    override func setUp() {
        super.setUp()
        mockAPI = MockTimelineAPI()
        service = StorjTimelineService(api: mockAPI)
    }

    // MARK: fetchEvents

    func test_fetch_empty_storj_returns_empty_array() async throws {
        let events = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        XCTAssertEqual(events.count, 0)
        XCTAssertEqual(mockAPI.listCallCount, 1)
    }

    func test_fetch_after_save_returns_event() async throws {
        let evt = TimelineEvent.fixture(id: "evt-001")
        _ = try await service.saveEvent(evt, walletAddress: wallet, encryptionKey: key)
        let fetched = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, "evt-001")
    }

    func test_fetch_error_propagates() async throws {
        mockAPI.listError = URLError(.notConnectedToInternet)
        do {
            _ = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    // MARK: saveEvent

    func test_save_event_returns_storj_uri() async throws {
        let evt = TimelineEvent.fixture(id: "evt-save-001")
        let result = try await service.saveEvent(evt, walletAddress: wallet, encryptionKey: key)
        XCTAssertTrue(result.storjUri.contains("evt-save-001"))
    }

    func test_save_event_increments_store_call_count() async throws {
        _ = try await service.saveEvent(.fixture(), walletAddress: wallet, encryptionKey: key)
        _ = try await service.saveEvent(.fixture(), walletAddress: wallet, encryptionKey: key)
        XCTAssertEqual(mockAPI.storeCallCount, 2)
    }

    func test_save_preserves_all_fields() async throws {
        let evt = TimelineEvent(
            id: "evt-fields-001",
            eventType: .medicationStarted,
            timestamp: Date(timeIntervalSince1970: 1_700_500_000),
            data: ["name": "Metformin", "dose": "500mg"],
            metadata: TimelineEventMetadata(platform: "ios", version: "1", source: .userEntered),
            attestationTxHash: "0xdeadbeef"
        )
        _ = try await service.saveEvent(evt, walletAddress: wallet, encryptionKey: key)

        let stored = mockAPI.lastStoredEvent
        XCTAssertEqual(stored?.id, "evt-fields-001")
        XCTAssertEqual(stored?.eventType, .medicationStarted)
        XCTAssertEqual(stored?.data["name"], "Metformin")
        XCTAssertEqual(stored?.data["dose"], "500mg")
        XCTAssertEqual(stored?.attestationTxHash, "0xdeadbeef")
    }

    func test_save_error_propagates() async throws {
        mockAPI.storeError = URLError(.timedOut)
        do {
            _ = try await service.saveEvent(.fixture(), walletAddress: wallet, encryptionKey: key)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    // MARK: deleteEvent

    func test_delete_event_removes_from_storj() async throws {
        let evt = TimelineEvent.fixture(id: "evt-del-001")
        _ = try await service.saveEvent(evt, walletAddress: wallet, encryptionKey: key)

        try await service.deleteEvent(id: "evt-del-001", walletAddress: wallet, encryptionKey: key)

        let remaining = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        XCTAssertEqual(remaining.count, 0)
        XCTAssertEqual(mockAPI.lastDeletedId, "evt-del-001")
    }

    func test_delete_only_removes_target_event() async throws {
        _ = try await service.saveEvent(.fixture(id: "evt-a"), walletAddress: wallet, encryptionKey: key)
        _ = try await service.saveEvent(.fixture(id: "evt-b"), walletAddress: wallet, encryptionKey: key)

        try await service.deleteEvent(id: "evt-a", walletAddress: wallet, encryptionKey: key)

        let remaining = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, "evt-b")
    }

    func test_delete_nonexistent_event_does_not_throw() async throws {
        // Should be idempotent — mock removes from empty store, no crash
        try await service.deleteEvent(id: "ghost-id", walletAddress: wallet, encryptionKey: key)
        XCTAssertEqual(mockAPI.deleteCallCount, 1)
    }

    func test_delete_error_propagates() async throws {
        mockAPI.deleteError = URLError(.cancelled)
        do {
            try await service.deleteEvent(id: "any", walletAddress: wallet, encryptionKey: key)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    // MARK: Round-trip

    func test_round_trip_add_fetch_compare() async throws {
        let original = TimelineEvent(
            id: "evt-round-trip",
            eventType: .conditionDiagnosed,
            timestamp: Date(timeIntervalSince1970: 1_700_123_456),
            data: ["condition": "Type 2 Diabetes", "diagnosed": "2025-11-01"],
            metadata: TimelineEventMetadata(platform: "ios", version: "1", source: .userEntered)
        )

        _ = try await service.saveEvent(original, walletAddress: wallet, encryptionKey: key)

        let fetched = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        let retrieved = fetched.first { $0.id == "evt-round-trip" }

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.eventType, original.eventType)
        XCTAssertEqual(retrieved?.data["condition"], original.data["condition"])
        XCTAssertEqual(retrieved?.data["diagnosed"], original.data["diagnosed"])
        XCTAssertEqual(
            retrieved?.timestamp.timeIntervalSince1970 ?? 0,
            original.timestamp.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    // MARK: syncAll

    func test_sync_all_with_empty_set_deletes_existing() async throws {
        _ = try await service.saveEvent(.fixture(id: "stale-a"), walletAddress: wallet, encryptionKey: key)
        _ = try await service.saveEvent(.fixture(id: "stale-b"), walletAddress: wallet, encryptionKey: key)

        try await service.syncAll([], walletAddress: wallet, encryptionKey: key)

        let remaining = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        XCTAssertEqual(remaining.count, 0)
        XCTAssertEqual(mockAPI.deleteCallCount, 2)
    }

    func test_sync_all_uploads_all_events() async throws {
        let events: [TimelineEvent] = [
            .fixture(id: "sync-1"),
            .fixture(id: "sync-2"),
            .fixture(id: "sync-3")
        ]

        try await service.syncAll(events, walletAddress: wallet, encryptionKey: key)

        let fetched = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        XCTAssertEqual(fetched.count, 3)
        let ids = Set(fetched.map(\.id))
        XCTAssertTrue(ids.contains("sync-1"))
        XCTAssertTrue(ids.contains("sync-2"))
        XCTAssertTrue(ids.contains("sync-3"))
    }

    func test_sync_all_removes_stale_keeps_new() async throws {
        // Upload stale event
        _ = try await service.saveEvent(.fixture(id: "stale"), walletAddress: wallet, encryptionKey: key)

        // Sync with new set (no "stale")
        let newEvents: [TimelineEvent] = [.fixture(id: "fresh-1"), .fixture(id: "fresh-2")]
        try await service.syncAll(newEvents, walletAddress: wallet, encryptionKey: key)

        let remaining = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        let ids = Set(remaining.map(\.id))
        XCTAssertFalse(ids.contains("stale"), "Stale event should be deleted")
        XCTAssertTrue(ids.contains("fresh-1"))
        XCTAssertTrue(ids.contains("fresh-2"))
    }

    func test_sync_all_preserves_overlapping_events() async throws {
        // Event exists in both old and new sets — should remain (not deleted)
        _ = try await service.saveEvent(.fixture(id: "keep"), walletAddress: wallet, encryptionKey: key)

        try await service.syncAll([.fixture(id: "keep"), .fixture(id: "new")],
                                  walletAddress: wallet,
                                  encryptionKey: key)

        let remaining = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        let ids = Set(remaining.map(\.id))
        XCTAssertTrue(ids.contains("keep"))
        XCTAssertTrue(ids.contains("new"))
        XCTAssertEqual(mockAPI.deleteCallCount, 0, "Overlapping event should not be deleted")
    }

    // MARK: Conflict resolution

    func test_storj_is_source_of_truth_on_sync() async throws {
        // Scenario: local has event A+B, Storj should have only B+C after sync
        _ = try await service.saveEvent(.fixture(id: "a"), walletAddress: wallet, encryptionKey: key)

        let authoritative: [TimelineEvent] = [.fixture(id: "b"), .fixture(id: "c")]
        try await service.syncAll(authoritative, walletAddress: wallet, encryptionKey: key)

        let storjState = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        let ids = Set(storjState.map(\.id))
        XCTAssertFalse(ids.contains("a"), "Event 'a' was not in the authoritative set — should be gone")
        XCTAssertTrue(ids.contains("b"))
        XCTAssertTrue(ids.contains("c"))
    }

    // MARK: JSON shape

    func test_saved_event_json_encodes_required_fields() throws {
        let evt = TimelineEvent.fixture(id: "json-shape-test", type: .injuryOccurred)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(evt)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json)
        XCTAssertEqual(json?["id"] as? String, "json-shape-test")
        XCTAssertEqual(json?["eventType"] as? String, TimelineEventType.injuryOccurred.rawValue)
        XCTAssertNotNil(json?["timestamp"], "timestamp must be present")
        XCTAssertNotNil(json?["data"], "data must be present")
        XCTAssertNotNil(json?["metadata"], "metadata must be present")
    }

    func test_deleted_event_is_absent_from_json_fetch() async throws {
        let evt = TimelineEvent.fixture(id: "delete-json-test")
        _ = try await service.saveEvent(evt, walletAddress: wallet, encryptionKey: key)
        try await service.deleteEvent(id: "delete-json-test", walletAddress: wallet, encryptionKey: key)

        let remaining = try await service.fetchEvents(walletAddress: wallet, encryptionKey: key)
        XCTAssertTrue(remaining.allSatisfy { $0.id != "delete-json-test" })
    }
}
