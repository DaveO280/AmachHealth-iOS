// TimelineService.swift
// AmachHealth
//
// Timeline events live in the vault (timeline_events), merged with local
// anomaly memory for display. Without a vault (no wallet) the feed shows
// anomaly memory only. Encrypted backup (BackupService) carries the events
// off the phone; nothing here talks to Storj.

import Foundation

@MainActor
final class TimelineService: ObservableObject {
    static let shared = TimelineService()

    @Published var events: [TimelineEvent] = []
    @Published var isLoading = false
    @Published var error: String?

    private var vault: VaultDatabase? { LocalVault.shared.database }

    private init() {}

    /// Called by LocalVault when the vault opens or closes.
    func vaultDidChange() {
        events = loadFromCache()
    }

    // MARK: - Public API

    func loadEvents() async {
        events = loadFromCache()
        error = nil
    }

    func addEvent(_ event: TimelineEvent) async throws {
        error = nil
        events.insert(event, at: 0)
        saveToCache(events)
    }

    func updateEvent(_ event: TimelineEvent) async throws {
        error = nil
        replaceLocalEvent(with: event)
    }

    func deleteEvent(id: String) async throws {
        error = nil
        events.removeAll { $0.id == id }
        try vault?.deleteTimelineEvent(id: id)
        timelineDebug("Removed timeline event \(id)")
    }

    // MARK: - Vault

    /// Vault events merged with local anomaly memory, newest first.
    private func loadFromCache() -> [TimelineEvent] {
        let stored = (try? vault?.timelineEvents()) ?? []
        let anomalies = HealthMemoryStore.shared.events.map(TimelineEvent.init(fromHealthEvent:))
        return merge(storjEvents: stored, anomalies: anomalies)
    }

    /// Persist user events to the vault. Anomaly events stay in HealthMemoryStore.
    private func saveToCache(_ events: [TimelineEvent]) {
        guard let vault else { return }
        let anomalyIds = Set(HealthMemoryStore.shared.events.map { TimelineEvent(fromHealthEvent: $0).id })
        try? vault.saveTimelineEvents(events.filter { !anomalyIds.contains($0.id) }, origin: "device")
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

    private func timelineDebug(_ message: String) {
        #if DEBUG
        print("🕒 [TimelineService] \(message)")
        #endif
    }
}
