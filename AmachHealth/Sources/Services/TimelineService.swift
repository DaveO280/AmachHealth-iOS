// TimelineService.swift
// AmachHealth
//
// Timeline events live in the vault (timeline_events), merged with local
// anomaly memory for display. Storj copies are written only while
// VaultFlags.legacyStorjWrites is on; without a vault (no wallet) the
// feed falls back to loading from Storj.

import Foundation

@MainActor
final class TimelineService: ObservableObject {
    static let shared = TimelineService()

    @Published var events: [TimelineEvent] = []
    @Published var isLoading = false
    @Published var error: String?

    private let storjService: StorjTimelineService
    private let wallet = WalletService.shared
    private var vault: VaultDatabase? { LocalVault.shared.database }

    private init(storjService: StorjTimelineService = .shared) {
        self.storjService = storjService
    }

    /// Called by LocalVault when the vault opens or closes.
    func vaultDidChange() {
        events = vault == nil ? [] : loadFromCache()
    }

    // MARK: - Public API

    func loadEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async {
        if vault != nil {
            // Local-first: the vault already holds imported Storj events.
            events = loadFromCache()
            error = nil
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        timelineDebug("Begin load for \(walletAddress)")

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
        guard VaultFlags.legacyStorjWrites else { return }

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
            // Saved in the vault already; the Storj copy is best-effort.
            if vault != nil { return }
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
        guard VaultFlags.legacyStorjWrites else { return }

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
            if vault != nil { return }
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
        try? vault?.deleteTimelineEvent(id: id)
        timelineDebug("Removed timeline event \(id) from local state")
        guard VaultFlags.legacyStorjWrites else { return }

        do {
            try await storjService.deleteEvent(
                id: id,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
            timelineDebug("Deleted timeline event \(id) from Storj")
        } catch {
            // With a vault the local delete stands; the Storj copy is best-effort.
            if vault != nil { return }
            // Rollback: re-insert the removed event
            if let event = removed.first {
                events.insert(event, at: 0)
                events.sort { $0.timestamp > $1.timestamp }
            }
            timelineDebug("Failed to delete timeline event \(id): \(error.localizedDescription)")
            self.error = error.localizedDescription
            throw error
        }
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
