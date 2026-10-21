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

    struct PeriodAverage: Equatable {
        /// `YYYY-MM` for months, `YYYY` for years.
        let period: String
        let value: Double
        /// Days with a value in the period.
        let days: Int
    }

    enum AverageGrouping {
        case month, year
        var prefixLength: Int { self == .month ? 7 : 4 }
    }

    /// Average of a daily value per month or year, over days where it's positive.
    /// `column` is the SQL value expression; nil uses the metric's primary value
    /// (the daily total for sum metrics and sleep, the mean otherwise).
    func periodAverages(
        metric: String, column: String? = nil, grouping: AverageGrouping,
        from startDay: String, through endDay: String
    ) throws -> [PeriodAverage] {
        let expr = column ?? (metric == AmachMetric.sleepId || AmachMetric.byId[metric]?.aggregation == .sum
                              ? "total" : "COALESCE(avg, total)")
        let sql = """
            SELECT substr(day, 1, \(grouping.prefixLength)) AS p, AVG(\(expr)) AS v, COUNT(*) AS n
            FROM daily_metrics
            WHERE metric = ? AND day >= ? AND day <= ? AND \(expr) > 0
            GROUP BY p ORDER BY p
            """
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [metric, startDay, endDay]).compactMap { row in
                guard let p: String = row["p"], let v: Double = row["v"] else { return nil }
                return PeriodAverage(period: p, value: v, days: row["n"] ?? 0)
            }
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
