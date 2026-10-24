// VaultRecords.swift
// AmachHealth
//
// GRDB row types for the vault tables. Column names match SCHEMA.md.

import Foundation
import GRDB

// MARK: - daily_metrics

struct DailyMetricRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "daily_metrics"

    enum Source: String {
        case healthKit = "healthkit"
        case importIOS = "import:ios"
        case importWeb = "import:web"
    }

    var day: String
    var metric: String
    var total: Double?
    var avg: Double?
    var min: Double?
    var max: Double?
    var count: Int
    var source: String
    var sleepInBedMin: Double?
    var sleepAwakeMin: Double?
    var sleepCoreMin: Double?
    var sleepDeepMin: Double?
    var sleepRemMin: Double?
    var sleepEfficiency: Double?
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case day, metric, total, avg, min, max, count, source
        case sleepInBedMin = "sleep_in_bed_min"
        case sleepAwakeMin = "sleep_awake_min"
        case sleepCoreMin = "sleep_core_min"
        case sleepDeepMin = "sleep_deep_min"
        case sleepRemMin = "sleep_rem_min"
        case sleepEfficiency = "sleep_efficiency"
        case updatedAt = "updated_at"
    }

    init(
        day: String, metric: String,
        total: Double? = nil, avg: Double? = nil, min: Double? = nil, max: Double? = nil,
        count: Int, source: Source,
        updatedAt: Date = Date()
    ) {
        self.day = day
        self.metric = metric
        self.total = total
        self.avg = avg
        self.min = min
        self.max = max
        self.count = count
        self.source = source.rawValue
        self.updatedAt = updatedAt.unixMillis
    }

    /// The value charts show: total for sums, avg otherwise.
    var primaryValue: Double? {
        if metric == AmachMetric.sleepId { return total }
        switch AmachMetric.byId[metric]?.aggregation {
        case .sum?: return total
        default: return avg ?? total
        }
    }
}

// MARK: - lab_reports / lab_markers

struct LabReportRow: Codable, Equatable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "lab_reports"

    enum Kind: String, Codable { case bloodwork, dexa, medical }

    var id: String
    var kind: String
    var reportDate: String?
    var laboratory: String?
    var sourcePdfSha256: String?
    var createdAt: Int64
    var subtype: String?
    var title: String?
    var source: String?
    var notes: String?
    var narrative: String?
    var fingerprint: String?
    var origin: String
    var storjKey: String?
    var attestationTxHash: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, laboratory, subtype, title, source, notes, narrative, fingerprint, origin
        case reportDate = "report_date"
        case sourcePdfSha256 = "source_pdf_sha256"
        case createdAt = "created_at"
        case storjKey = "storj_key"
        case attestationTxHash = "attestation_tx_hash"
    }

    var kindValue: Kind { Kind(rawValue: kind) ?? .medical }
}

struct LabMarkerRow: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "lab_markers"

    var id: Int64?
    var reportId: String
    var position: Int
    var name: String
    var canonicalName: String
    var value: Double?
    var valueText: String?
    var unit: String?
    var referenceRange: String?
    var flag: String?
    var panel: String?

    enum CodingKeys: String, CodingKey {
        case id, position, name, value, unit, flag, panel
        case reportId = "report_id"
        case canonicalName = "canonical_name"
        case valueText = "value_text"
        case referenceRange = "reference_range"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// "Vitamin D, 25-OH" → "vitamin_d_25_oh"
    static func canonicalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        var out = ""
        var lastUnderscore = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastUnderscore = false
            } else if !lastUnderscore {
                out.append("_")
                lastUnderscore = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return out.isEmpty ? "unnamed" : out
    }
}

/// A report with its markers, as the UI and Luma read it.
struct LabReportWithMarkers: Identifiable, Equatable {
    var report: LabReportRow
    var markers: [LabMarkerRow]
    var id: String { report.id }
}

// MARK: - timeline_events

struct TimelineEventRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "timeline_events"

    var id: String
    var eventType: String
    var occurredAt: Int64
    var dataJson: String
    var metadataJson: String
    var anomalyType: String?
    var metric: String?
    var direction: String?
    var deviationPct: Double?
    var resolvedAt: Int64?
    var attestationTxHash: String?
    var origin: String
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, metric, direction, origin
        case eventType = "event_type"
        case occurredAt = "occurred_at"
        case dataJson = "data_json"
        case metadataJson = "metadata_json"
        case anomalyType = "anomaly_type"
        case deviationPct = "deviation_pct"
        case resolvedAt = "resolved_at"
        case attestationTxHash = "attestation_tx_hash"
        case updatedAt = "updated_at"
    }
}

// MARK: - chat_sessions / chat_messages

struct ChatSessionRow: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chat_sessions"

    var id: String
    var createdAt: Int64
    var updatedAt: Int64
    var isCurrent: Bool
    var healthSummary: String?
    var rollingSummary: String?
    var storjUri: String?
    var origin: String

    enum CodingKeys: String, CodingKey {
        case id, origin
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isCurrent = "is_current"
        case healthSummary = "health_summary"
        case rollingSummary = "rolling_summary"
        case storjUri = "storj_uri"
    }
}

struct ChatMessageRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "chat_messages"

    var id: String
    var sessionId: String
    var position: Int
    var role: String
    var content: String
    var createdAt: Int64
    var metadataJson: String?
    var feedback: String?

    enum CodingKeys: String, CodingKey {
        case id, position, role, content, feedback
        case sessionId = "session_id"
        case createdAt = "created_at"
        case metadataJson = "metadata_json"
    }
}

// MARK: - memory_facts / memory_summaries

struct MemoryFactRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory_facts"

    var id: String
    var category: String
    var value: String
    var context: String?
    var identifiedAt: Int64
    var lastConfirmedAt: Int64?
    var isActive: Bool
    var sourceEventId: String?

    enum CodingKeys: String, CodingKey {
        case id, category, value, context
        case identifiedAt = "identified_at"
        case lastConfirmedAt = "last_confirmed_at"
        case isActive = "is_active"
        case sourceEventId = "source_event_id"
    }
}

struct MemorySummaryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory_summaries"

    var id: String
    var date: Int64
    var summary: String
    var topicsJson: String
    var importance: String
    var messageCount: Int

    enum CodingKeys: String, CodingKey {
        case id, date, summary, importance
        case topicsJson = "topics_json"
        case messageCount = "message_count"
    }
}

// MARK: - merkle_leaves / merkle_roots

struct MerkleLeafRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "merkle_leaves"

    var dayId: Int
    var leafVersion: Int
    var fields: String
    var hash: String

    enum CodingKeys: String, CodingKey {
        case fields, hash
        case dayId = "day_id"
        case leafVersion = "leaf_version"
    }
}

struct MerkleRootRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "merkle_roots"

    var root: String
    var startDay: Int
    var endDay: Int
    var txHash: String?
    var leafCount: Int?
    var treeDepth: Int?
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case root
        case startDay = "start_day"
        case endDay = "end_day"
        case txHash = "tx_hash"
        case leafCount = "leaf_count"
        case treeDepth = "tree_depth"
        case createdAt = "created_at"
    }
}

// MARK: - backup_state / healthkit_sync / storj_imports

struct BackupStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "backup_state"

    var recordType: String
    var recordId: String
    var localVersion: Int
    var backedUpVersion: Int

    enum CodingKeys: String, CodingKey {
        case recordType = "record_type"
        case recordId = "record_id"
        case localVersion = "local_version"
        case backedUpVersion = "backed_up_version"
    }
}

struct HealthKitSyncRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "healthkit_sync"

    var stream: String
    var anchor: Data?
    var backfilledFrom: String?
    var earliestDay: String?
    var updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case stream, anchor
        case backfilledFrom = "backfilled_from"
        case earliestDay = "earliest_day"
        case updatedAt = "updated_at"
    }
}

struct StorjImportRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "storj_imports"

    enum Status: String, Codable { case imported, duplicate, archived, failed }

    var objectKey: String
    var dataType: String
    var uploadedAt: Int64
    var size: Int
    var status: String
    var recordType: String?
    var recordId: String?
    var detail: String?
    var payloadJson: String?
    var importedAt: Int64

    enum CodingKeys: String, CodingKey {
        case size, status, detail
        case objectKey = "object_key"
        case dataType = "data_type"
        case uploadedAt = "uploaded_at"
        case recordType = "record_type"
        case recordId = "record_id"
        case payloadJson = "payload_json"
        case importedAt = "imported_at"
    }
}
