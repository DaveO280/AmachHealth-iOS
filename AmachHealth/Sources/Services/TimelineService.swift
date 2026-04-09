// TimelineService.swift
// AmachHealth
//
// Loads timeline events from Storj, merges them with local anomaly memory,
// and caches the combined feed for fast startup.

import Foundation

@MainActor
final class TimelineService: ObservableObject {
    static let shared = TimelineService()

    @Published var events: [TimelineEvent] = []
    @Published var isLoading = false
    @Published var error: String?

    private let storjService: StorjTimelineService
    private let wallet = WalletService.shared
    private let cacheKey = "amach_timeline_events"

    private init(storjService: StorjTimelineService = .shared) {
        self.storjService = storjService
        events = loadFromCache()
    }

    // MARK: - Public API

    func loadEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async {
        let cachedEvents = loadFromCache()
        events = cachedEvents
        isLoading = true
        error = nil
        defer { isLoading = false }

        timelineDebug("Begin load for \(walletAddress)")
        timelineDebug("Loaded \(cachedEvents.count) cached timeline events")

        do {
            let storjEvents = try await loadStorjEvents(
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
            let anomalyEvents = HealthMemoryStore.shared.events.map(TimelineEvent.init(fromHealthEvent:))
            timelineDebug("Loaded \(storjEvents.count) Storj timeline events")
            timelineDebug("Loaded \(anomalyEvents.count) local anomaly events")
            let merged = merge(storjEvents: storjEvents, anomalies: anomalyEvents)
            events = merged
            saveToCache(merged)
            timelineDebug("Merged timeline now has \(merged.count) events")
        } catch {
            timelineDebug("Timeline load failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    func addEvent(
        _ event: TimelineEvent,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws {
        error = nil
        events.insert(event, at: 0)
        saveToCache(events)

        do {
            let storeResult = try await storjService.saveEvent(
                event,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
            timelineDebug("Stored timeline event \(event.id) at \(storeResult.storjUri)")

            var storedEvent = event
            if let attestation = try? await AmachAPIClient.shared.createAttestation(
                storjUri: storeResult.storjUri,
                dataType: "timeline-event",
                action: "store",
                walletAddress: walletAddress,
                encryptionKey: encryptionKey,
                metadata: ["eventType": event.eventType.rawValue]
            ) {
                storedEvent.attestationTxHash = attestation.txHash
            }

            replaceLocalEvent(with: storedEvent)
        } catch {
            timelineDebug("Failed to store timeline event \(event.id): \(error.localizedDescription)")
            events.removeAll { $0.id == event.id }
            saveToCache(events)
            self.error = error.localizedDescription
            throw error
        }
    }

    func updateEvent(
        _ event: TimelineEvent,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws {
        error = nil
        replaceLocalEvent(with: event)

        do {
            let storeResult = try await storjService.saveEvent(
                event,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
            timelineDebug("Updated timeline event \(event.id) at \(storeResult.storjUri)")

            var storedEvent = event
            if let attestation = try? await AmachAPIClient.shared.createAttestation(
                storjUri: storeResult.storjUri,
                dataType: "timeline-event",
                action: "update",
                walletAddress: walletAddress,
                encryptionKey: encryptionKey,
                metadata: ["eventType": event.eventType.rawValue]
            ) {
                storedEvent.attestationTxHash = attestation.txHash
            }

            replaceLocalEvent(with: storedEvent)
        } catch {
            timelineDebug("Failed to update timeline event \(event.id): \(error.localizedDescription)")
            self.error = error.localizedDescription
            throw error
        }
    }

    func deleteEvent(
        id: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws {
        error = nil
        // Optimistic local removal
        let removed = events.filter { $0.id == id }
        events.removeAll { $0.id == id }
        saveToCache(events)
        timelineDebug("Optimistically removed timeline event \(id) from local state")

        do {
            try await storjService.deleteEvent(
                id: id,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
            timelineDebug("Deleted timeline event \(id) from Storj")
        } catch {
            // Rollback: re-insert the removed event
            if let event = removed.first {
                events.insert(event, at: 0)
                events.sort { $0.timestamp > $1.timestamp }
                saveToCache(events)
            }
            timelineDebug("Failed to delete timeline event \(id): \(error.localizedDescription)")
            self.error = error.localizedDescription
            throw error
        }
    }

    // MARK: - Cache

    private func loadFromCache() -> [TimelineEvent] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TimelineEvent].self, from: data)) ?? []
    }

    private func saveToCache(_ events: [TimelineEvent]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private func replaceLocalEvent(with event: TimelineEvent) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        saveToCache(events)
    }

    private func merge(
        storjEvents: [TimelineEvent],
        anomalies: [TimelineEvent]
    ) -> [TimelineEvent] {
        var byID: [String: TimelineEvent] = [:]

        for event in anomalies {
            byID[event.id] = event
        }

        for event in storjEvents {
            byID[event.id] = event
        }

        return byID.values.sorted { $0.timestamp > $1.timestamp }
    }

    private func loadStorjEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [TimelineEvent] {
        do {
            timelineDebug("Attempting Storj timeline load with current encryption key")
            return try await storjService.fetchEvents(
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
        } catch {
            timelineDebug("Storj timeline load failed with current key: \(error.localizedDescription)")
            guard shouldRetryWithFreshSignature(error) else {
                timelineDebug("Will not retry with fresh signature")
                throw error
            }

            timelineDebug("Retrying timeline load after forcing encryption key refresh")
            let refreshedKey = try await wallet.ensureEncryptionKey(forceRefresh: true)
            return try await storjService.fetchEvents(
                walletAddress: walletAddress,
                encryptionKey: refreshedKey
            )
        }
    }

    private func shouldRetryWithFreshSignature(_ error: Error) -> Bool {
        if wallet.encryptionKey == nil {
            return true
        }

        let message = error.localizedDescription.lowercased()
        let retryTriggers = [
            "encryption",
            "decrypt",
            "decryption",
            "signature",
            "key mismatch",
            "invalid key",
            "failed to decode",
            "substring"
        ]

        return retryTriggers.contains { message.contains($0) }
    }

    private func timelineDebug(_ message: String) {
        #if DEBUG
        print("🕒 [TimelineService] \(message)")
        #endif
    }
}
