// VaultDatabase+Metrics.swift
// AmachHealth
//
// daily_metrics reads and writes.

import Foundation
import GRDB

extension VaultDatabase {

    enum MetricWritePolicy {
        /// HealthKit is authoritative for the days it covers.
        case overwrite
        /// Imports only fill days the vault doesn't have, or that an earlier import wrote.
        case fillImportedOnly
    }

    @discardableResult
    func upsertDailyMetrics(_ rows: [DailyMetricRow], policy: MetricWritePolicy) throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try dbQueue.write { db in
            var written = 0
            for row in rows {
                if policy == .fillImportedOnly,
                   let existing = try DailyMetricRow.fetchOne(db, key: ["day": row.day, "metric": row.metric]),
                   existing.source == DailyMetricRow.Source.healthKit.rawValue {
                    continue
                }
                try row.save(db)
                written += 1
            }
            return written
        }
    }

    func dailyMetrics(metric: String, from startDay: String, through endDay: String) throws -> [DailyMetricRow] {
        try dbQueue.read { db in
            try DailyMetricRow
                .filter(Column("metric") == metric && Column("day") >= startDay && Column("day") <= endDay)
                .order(Column("day"))
                .fetchAll(db)
        }
    }

    func dailyMetric(metric: String, day: String) throws -> DailyMetricRow? {
        try dbQueue.read { db in
            try DailyMetricRow.fetchOne(db, key: ["day": day, "metric": metric])
        }
    }

    /// Most recent row on or before `day` with a value (e.g. VO2 max, which isn't measured daily).
    func latestDailyMetric(metric: String, onOrBefore day: String) throws -> DailyMetricRow? {
        try dbQueue.read { db in
            try DailyMetricRow
                .filter(Column("metric") == metric && Column("day") <= day)
                .order(Column("day").desc)
                .fetchOne(db)
        }
    }

    func dailyMetricCount() throws -> Int {
        try dbQueue.read { db in try DailyMetricRow.fetchCount(db) }
    }

    func dailyMetricDayRange() throws -> (first: String, last: String)? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT MIN(day) AS a, MAX(day) AS b FROM daily_metrics"),
                  let first: String = row["a"], let last: String = row["b"] else { return nil }
            return (first, last)
        }
    }
}

extension VaultDatabase {
    /// Remove HealthKit sleep rows for these days (imports are left alone).
    func deleteHealthKitSleepRows(days: [String]) throws {
        guard !days.isEmpty else { return }
        try dbQueue.write { db in
            for day in days {
                try db.execute(
                    sql: "DELETE FROM daily_metrics WHERE metric = ? AND day = ? AND source = ?",
                    arguments: [AmachMetric.sleepId, day, DailyMetricRow.Source.healthKit.rawValue]
                )
            }
        }
    }
}
