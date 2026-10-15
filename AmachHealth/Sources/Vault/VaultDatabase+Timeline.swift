// VaultDatabase+Timeline.swift
// AmachHealth
//
// timeline_events reads and writes. The flexible parts of an event (data,
// metadata) are kept as JSON; the fields anything queries on are columns.

import Foundation
import GRDB

extension VaultDatabase {

    func saveTimelineEvents(_ events: [TimelineEvent], origin: String) throws {
        guard !events.isEmpty else { return }
        try dbQueue.write { db in
            for event in events {
                var row = TimelineEventRow(event: event, origin: origin)
                if var existing = try TimelineEventRow.fetchOne(db, key: row.id) {
                    row.origin = existing.origin
                    // Keep an imported type this app shows as CUSTOM.
                    if event.eventType == .custom, TimelineEventType(rawValue: existing.eventType) == nil {
                        row.eventType = existing.eventType
                    }
                    existing.updatedAt = row.updatedAt
                    if existing == row { continue }  // unchanged: don't bump backup_state
                }
                try row.save(db)
            }
        }
    }

    /// Insert events whose id the vault doesn't have yet. Returns how many were new.
    func insertMissingTimelineEvents(_ events: [TimelineEvent], origin: String) throws -> Int {
        try dbQueue.write { db in
            var inserted = 0
            for event in events where try !TimelineEventRow.exists(db, key: event.id) {
                try TimelineEventRow(event: event, origin: origin).insert(db)
                inserted += 1
            }
            return inserted
        }
    }

    func deleteTimelineEvent(id: String) throws {
        _ = try dbQueue.write { db in try TimelineEventRow.deleteOne(db, key: id) }
    }

    func timelineEvents() throws -> [TimelineEvent] {
        try dbQueue.read { db in
            try TimelineEventRow.order(Column("occurred_at").desc).fetchAll(db)
        }.compactMap(\.event)
    }

    func timelineEventCount() throws -> Int {
        try dbQueue.read { db in try TimelineEventRow.fetchCount(db) }
    }
}

extension TimelineEventRow {
    init(event: TimelineEvent, origin: String) {
        let encoder = VaultJSON.encoder
        id = event.id
        eventType = event.eventType.rawValue
        occurredAt = event.timestamp.unixMillis
        dataJson = (try? String(decoding: encoder.encode(event.data), as: UTF8.self)) ?? "{}"
        metadataJson = (try? String(decoding: encoder.encode(event.metadata), as: UTF8.self)) ?? "{}"
        anomalyType = event.anomalyType
        metric = event.metricType
        direction = event.direction
        deviationPct = event.deviationPct
        resolvedAt = event.resolvedAt?.unixMillis
        attestationTxHash = event.attestationTxHash
        self.origin = origin
        updatedAt = Date().unixMillis
    }

    /// Types this app doesn't know show as CUSTOM (as TimelineEvent decoding
    /// does); the original type stays in the event_type column.
    var event: TimelineEvent? {
        let type = TimelineEventType(rawValue: eventType) ?? .custom
        let decoder = VaultJSON.decoder
        let data = (try? decoder.decode([String: String].self, from: Data(dataJson.utf8))) ?? [:]
        let metadata = (try? decoder.decode(TimelineEventMetadata.self, from: Data(metadataJson.utf8)))
            ?? TimelineEventMetadata(platform: "unknown", version: "1", source: .userEntered)
        return TimelineEvent(
            id: id, eventType: type, timestamp: Date(unixMillis: occurredAt),
            data: data, metadata: metadata,
            anomalyType: anomalyType, metricType: metric, direction: direction,
            deviationPct: deviationPct, resolvedAt: resolvedAt.map(Date.init(unixMillis:)),
            attestationTxHash: attestationTxHash
        )
    }
}
