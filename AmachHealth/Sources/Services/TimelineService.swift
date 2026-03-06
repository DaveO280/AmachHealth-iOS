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

    private let api = AmachAPIClient.shared
    private let cacheKey = "amach_timeline_events"

    private init() {
        events = loadFromCache()
    }

    // MARK: - Public API

    func loadEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async {
        events = loadFromCache()
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let storjEvents = try await api.listTimelineEvents(
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
            let anomalyEvents = HealthMemoryStore.shared.events.map(TimelineEvent.init(fromHealthEvent:))
            let merged = merge(storjEvents: storjEvents, anomalies: anomalyEvents)
            events = merged
            saveToCache(merged)
        } catch {
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
            let storeResult = try await api.storeTimelineEvent(
                event: event,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )

            var storedEvent = event
            if let attestation = try? await api.createAttestation(
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
            events.removeAll { $0.id == event.id }
            saveToCache(events)
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
}
