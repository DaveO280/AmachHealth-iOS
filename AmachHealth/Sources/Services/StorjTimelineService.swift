// StorjTimelineService.swift
// AmachHealth
//
// Storj I/O adapter for timeline events — injectable for testing.
// Provides fetch / save / delete / syncAll, keeping business logic
// (caching, merge, attestation) in TimelineService and pure Storj
// transport here.
//
// TimelineService delegates all Storj calls here; tests inject a mock
// that conforms to TimelineAPIProtocol.

import Foundation

// MARK: - Protocol

/// Minimal Storj operations that StorjTimelineService needs from AmachAPIClient.
/// AmachAPIClient already implements all three methods; conformance is declared
/// via extension at the bottom of this file.
protocol TimelineAPIProtocol {
    func storeTimelineEvent(
        event: TimelineEvent,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult

    func listTimelineEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [TimelineEvent]

    func deleteTimelineEvent(
        eventId: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws
}

// MARK: - StorjTimelineService

/// Pure Storj transport for timeline events.
/// Thread-safe — no actor isolation; all async/await.
final class StorjTimelineService {

    static let shared = StorjTimelineService()

    private let api: any TimelineAPIProtocol

    init(api: any TimelineAPIProtocol = AmachAPIClient.shared) {
        self.api = api
    }

    // MARK: - Public interface

    /// Download all timeline events stored for `walletAddress`.
    func fetchEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [TimelineEvent] {
        try await api.listTimelineEvents(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
    }

    /// Upload a single event to Storj. Returns the store result (URI + hash).
    @discardableResult
    func saveEvent(
        _ event: TimelineEvent,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        try await api.storeTimelineEvent(
            event: event,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
    }

    /// Remove an event from Storj by its string id.
    /// Idempotent — no-op if the event is not found on Storj.
    func deleteEvent(
        id: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws {
        try await api.deleteTimelineEvent(
            eventId: id,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
    }

    /// Replace the full Storj timeline with `events`.
    /// - Deletes any Storj objects whose event ID is absent from `events`.
    /// - Uploads all events in `events` (new and updated).
    /// Storj is the source of truth after this call.
    func syncAll(
        _ events: [TimelineEvent],
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws {
        let existing = try await api.listTimelineEvents(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
        let newIds = Set(events.map(\.id))

        // Remove stale events concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for stale in existing where !newIds.contains(stale.id) {
                let staleid = stale.id
                group.addTask { [api] in
                    try await api.deleteTimelineEvent(
                        eventId: staleid,
                        walletAddress: walletAddress,
                        encryptionKey: encryptionKey
                    )
                }
            }
            try await group.waitForAll()
        }

        // Upload all events sequentially to avoid hammering the backend
        for event in events {
            try await api.storeTimelineEvent(
                event: event,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
        }
    }
}

// MARK: - AmachAPIClient conformance

/// AmachAPIClient already has storeTimelineEvent and listTimelineEvents;
/// deleteTimelineEvent is implemented in AmachAPIClient.swift.
extension AmachAPIClient: TimelineAPIProtocol {}
