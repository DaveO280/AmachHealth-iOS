// HealthKitIngestionService.swift
// AmachHealth
//
// Keeps daily_metrics in step with HealthKit. HealthKit stays the source of
// raw samples; the vault holds one aggregate row per day and metric.
//
//   • Backfill: all available history, newest first, in 30-day windows.
//     Progress is saved after each window, so it resumes after a relaunch.
//   • Current: an observer + anchored query per stream (background delivery
//     on), watching the last 30 days. A change re-aggregates the affected days.
//
// Aggregation follows HealthKitService.buildDailySummaries (day = local
// calendar day of the sample start; sleep goes to the day it ends; the same
// sleep-stage rules), with one difference: daily totals for sum metrics come
// from HKStatisticsCollectionQuery, which removes Watch/iPhone overlap that a
// raw sum would double-count.
//
// The vault file is protected while the phone is locked, so a background
// write can fail; the anchor only moves after a successful write.

import Foundation
import HealthKit

@MainActor
final class HealthKitIngestionService: ObservableObject {
    static let shared = HealthKitIngestionService()

    struct BackfillProgress: Equatable {
        var windowsDone: Int
        var windowsTotal: Int
        var oldestDayDone: String?
        var isRunning: Bool

        var fraction: Double { windowsTotal == 0 ? 1 : Double(windowsDone) / Double(windowsTotal) }
    }

    @Published private(set) var backfill: BackfillProgress?
    @Published private(set) var lastError: String?

    private let store = HKHealthStore()
    private var vault: VaultDatabase?
    private var observers: [HKObserverQuery] = []
    private var backfillTask: Task<Void, Never>?

    static let windowDays = 30
    static let liveWindowDays = 30
    private static let backfillFromKey = "hk_backfill_from"
    private static let backfillCompleteKey = "hk_backfill_complete"

    private init() {}

    // MARK: - Streams

    enum Stream: Hashable {
        case quantity(AmachMetric)
        case sleep
        case workouts
        case mindful

        var id: String {
            switch self {
            case .quantity(let m): return m.id
            case .sleep: return AmachMetric.sleepId
            case .workouts: return AmachMetric.workoutMinutesId
            case .mindful: return AmachMetric.mindfulMinutesId
            }
        }

        var sampleType: HKSampleType? {
            switch self {
            case .quantity(let m): return m.healthKit.flatMap { HKQuantityType.quantityType(forIdentifier: $0) }
            case .sleep: return HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)
            case .workouts: return HKObjectType.workoutType()
            case .mindful: return HKCategoryType.categoryType(forIdentifier: .mindfulSession)
            }
        }
    }

    /// Metrics HealthKitService already asks permission for. Others in
    /// AmachMetric are filled by imports only, so the permission prompt is unchanged.
    nonisolated static var streams: [Stream] {
        let requested = Set(HealthKitMetric.allCases.map(\.rawValue))
        let quantities = AmachMetric.all
            .filter { $0.healthKit.map { requested.contains($0.rawValue) } ?? false }
            .map(Stream.quantity)
        return quantities + [.sleep, .workouts, .mindful]
    }

    // MARK: - Lifecycle

    func start(vault: VaultDatabase) {
        stop()
        guard HKHealthStore.isHealthDataAvailable() else { return }
        self.vault = vault
        startObservers()
        backfillTask = Task { [weak self] in await self?.runBackfill() }
    }

    func stop() {
        backfillTask?.cancel()
        backfillTask = nil
        observers.forEach { store.stop($0) }
        observers = []
        vault = nil
    }

    /// Re-aggregate today and yesterday (dashboard pull-to-refresh, app open).
    func refreshRecent() async {
        guard let vault else { return }
        let cal = Calendar.current
        let end = Date()
        let start = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: end)) ?? end
        await ingest(range: start..<end, streams: Self.streams, into: vault)
    }

    // MARK: - Backfill

    private func runBackfill() async {
        guard let vault else { return }
        if (try? vault.meta(Self.backfillCompleteKey)) != nil {
            // History done; still re-ingest the recent window in case the app was off.
            await refreshRecent()
            await reaggregateSleepIfNeeded()
            return
        }

        let cal = Calendar.current
        let streams = Self.streams
        let earliest = await earliestSampleDate(streams: streams) ?? Date()
        let earliestStart = cal.startOfDay(for: earliest)
        let todayEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()

        var windowEnd = todayEnd
        if let doneFrom = (try? vault.meta(Self.backfillFromKey)).flatMap({ $0 }).flatMap(VaultDay.date) {
            // Resume: refresh the recent window, then continue below what's done.
            await refreshRecent()
            windowEnd = doneFrom
        }

        let totalDays = max(1, cal.dateComponents([.day], from: earliestStart, to: todayEnd).day ?? 1)
        let total = Int((Double(totalDays) / Double(Self.windowDays)).rounded(.up))
        let remainingDays = max(0, cal.dateComponents([.day], from: earliestStart, to: windowEnd).day ?? 0)
        let remaining = Int((Double(remainingDays) / Double(Self.windowDays)).rounded(.up))
        backfill = BackfillProgress(windowsDone: total - remaining, windowsTotal: total,
                                    oldestDayDone: windowEnd.vaultDay, isRunning: true)

        while windowEnd > earliestStart, !Task.isCancelled {
            let windowStart = max(earliestStart, cal.date(byAdding: .day, value: -Self.windowDays, to: windowEnd) ?? earliestStart)
            let ok = await ingest(range: windowStart..<windowEnd, streams: streams, into: vault)
            guard ok else {
                // Usually the phone locked mid-write; try again on next start.
                backfill?.isRunning = false
                return
            }
            try? vault.setMeta(Self.backfillFromKey, windowStart.vaultDay)
            windowEnd = windowStart
            backfill?.windowsDone += 1
            backfill?.oldestDayDone = windowStart.vaultDay
        }

        if !Task.isCancelled {
            try? vault.setMeta(Self.sleepSessionsKey, Date().vaultDay)
            try? vault.setMeta(Self.backfillCompleteKey, Date().vaultDay)
            backfill?.isRunning = false
            backfill?.windowsDone = backfill?.windowsTotal ?? 0
            await DashboardService.shared.load(force: true)
        }
    }

    /// Vaults backfilled before sleep sessions split nights at midnight;
    /// rebuild every sleep row once with the session rules.
    static let sleepSessionsKey = "hk_sleep_sessions_v1"

    private func reaggregateSleepIfNeeded() async {
        guard let vault, (try? vault.meta(Self.sleepSessionsKey)) ?? nil == nil else { return }
        let cal = Calendar.current
        guard let earliest = await earliestSampleDate(streams: [.sleep]) else {
            try? vault.setMeta(Self.sleepSessionsKey, Date().vaultDay)
            return
        }
        let earliestStart = cal.startOfDay(for: earliest)
        var windowEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        while windowEnd > earliestStart, !Task.isCancelled {
            let windowStart = max(earliestStart, cal.date(byAdding: .day, value: -Self.windowDays, to: windowEnd) ?? earliestStart)
            guard await ingest(range: windowStart..<windowEnd, streams: [.sleep], into: vault) else { return }
            windowEnd = windowStart
        }
        if !Task.isCancelled {
            try? vault.setMeta(Self.sleepSessionsKey, Date().vaultDay)
            await DashboardService.shared.load(force: true)
        }
    }

    private func earliestSampleDate(streams: [Stream]) async -> Date? {
        var earliest: Date?
        for stream in streams {
            guard let type = stream.sampleType else { continue }
            if let date = await Self.firstSampleDate(store: store, type: type) {
                earliest = min(earliest ?? date, date)
            }
        }
        return earliest
    }

    // MARK: - Live updates

    private func startObservers() {
        for stream in Self.streams {
            guard let type = stream.sampleType else { continue }
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard error == nil else { completion(); return }
                Task { @MainActor in
                    await self?.handleChange(stream)
                    completion()
                }
            }
            observers.append(query)
            store.execute(query)
        }
    }

    private func handleChange(_ stream: Stream) async {
        guard let vault, let type = stream.sampleType else { return }
        let anchorRow = try? await vault.dbQueue.read { db in try HealthKitSyncRow.fetchOne(db, key: stream.id) }
        let anchor = anchorRow?.anchor.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -Self.liveWindowDays, to: cal.startOfDay(for: Date())) ?? Date()

        guard let result = await Self.anchoredChanges(store: store, type: type, since: since, anchor: anchor) else { return }

        // Days touched by added samples; deletions carry no dates, so redo the last two days.
        var days = Set(result.days)
        if stream == .sleep {
            // A sample before midnight belongs to the night that ends the next day.
            for day in result.days {
                if let date = VaultDay.date(day), let next = cal.date(byAdding: .day, value: 1, to: date), next <= Date() {
                    days.insert(next.vaultDay)
                }
            }
        }
        if result.hadDeletions || anchor == nil {
            days.insert(Date().vaultDay)
            days.insert((cal.date(byAdding: .day, value: -1, to: Date()) ?? Date()).vaultDay)
        }
        for day in days.sorted() {
            guard let start = VaultDay.date(day), let end = cal.date(byAdding: .day, value: 1, to: start) else { continue }
            let ok = await ingest(range: start..<end, streams: [stream], into: vault)
            if !ok { return }  // leave the anchor; retry next delivery
        }

        let data = result.newAnchor.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        try? await vault.dbQueue.write { db in
            try HealthKitSyncRow(stream: stream.id, anchor: data, backfilledFrom: nil,
                                 earliestDay: nil, updatedAt: Date().unixMillis).save(db)
        }
        if days.contains(Date().vaultDay) {
            await DashboardService.shared.load(force: true)
        }
    }

    // MARK: - Aggregate + write

    /// Aggregate every stream for the days in `range` and upsert. Returns false on a write failure.
    @discardableResult
    private func ingest(range: Range<Date>, streams: [Stream], into vault: VaultDatabase) async -> Bool {
        var rows: [DailyMetricRow] = []
        for stream in streams {
            rows += await Self.aggregate(stream: stream, range: range, store: store)
        }
        do {
            try vault.upsertDailyMetrics(rows, policy: .overwrite)
            if streams.contains(.sleep) {
                // Days in range with no night ending on them lose any old
                // HealthKit sleep row (e.g. a pre-midnight fragment).
                let kept = Set(rows.filter { $0.metric == AmachMetric.sleepId }.map(\.day))
                let stale = Set(stride(from: range.lowerBound, to: range.upperBound, by: 3600).map(\.vaultDay)).subtracting(kept)
                try vault.deleteHealthKitSleepRows(days: Array(stale))
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    nonisolated static func aggregate(stream: Stream, range: Range<Date>, store: HKHealthStore) async -> [DailyMetricRow] {
        switch stream {
        case .quantity(let metric):
            guard let type = stream.sampleType as? HKQuantityType, let unit = metric.healthKitUnit else { return [] }
            let samples = await quantitySamples(store: store, type: type, range: range)
            var totals: [String: Double] = [:]
            if metric.aggregation == .sum {
                totals = await dailySums(store: store, type: type, unit: unit, range: range)
            }
            let values = samples.map { (day: $0.startDate.vaultDay, value: $0.quantity.doubleValue(for: unit) * metric.healthKitScale) }
            return quantityRows(metric: metric, values: values, dedupedTotals: totals)
        case .sleep:
            // Fetch from a day earlier so a night that ends in range is whole,
            // then keep only nights that end in range (SleepSessions.swift).
            let samples = await sleepSamples(store: store, range: range)
            let days = Set(stride(from: range.lowerBound, to: range.upperBound, by: 3600).map(\.vaultDay))
            return sleepRows(samples).filter { days.contains($0.day) }
        case .mindful:
            let samples = await categorySamples(store: store, type: stream.sampleType, range: range, byEnd: false)
            return durationRows(metric: AmachMetric.mindfulMinutesId,
                                items: samples.map { ($0.startDate.vaultDay, $0.endDate.timeIntervalSince($0.startDate) / 60) })
        case .workouts:
            let workouts = await workoutSamples(store: store, range: range)
            return durationRows(metric: AmachMetric.workoutMinutesId,
                                items: workouts.map { ($0.startDate.vaultDay, $0.duration / 60) })
        }
    }

    // MARK: Pure aggregation (unit-tested)

    nonisolated static func quantityRows(
        metric: AmachMetric,
        values: [(day: String, value: Double)],
        dedupedTotals: [String: Double],
        now: Date = Date()
    ) -> [DailyMetricRow] {
        Dictionary(grouping: values, by: \.day).compactMap { day, items -> DailyMetricRow? in
            let v = items.map(\.value)
            guard !v.isEmpty else { return nil }
            let sum = v.reduce(0, +)
            switch metric.aggregation {
            case .sum:
                return DailyMetricRow(day: day, metric: metric.id, total: dedupedTotals[day] ?? sum,
                                      count: v.count, source: .healthKit, updatedAt: now)
            case .range, .average:
                return DailyMetricRow(day: day, metric: metric.id, avg: sum / Double(v.count),
                                      min: v.min(), max: v.max(), count: v.count, source: .healthKit, updatedAt: now)
            }
        }
    }

    /// One row per day: every sleep session that ends that day, counting one
    /// source per night (SleepSessionBuilder). Stage rules as before:
    /// unspecified asleep counts as core; total = core + deep + REM.
    nonisolated static func sleepRows(_ samples: [SleepSample], now: Date = Date()) -> [DailyMetricRow] {
        Dictionary(grouping: SleepSessionBuilder.sessions(samples), by: \.day).map { day, sessions in
            let inBed = sessions.reduce(0) { $0 + $1.inBedMinutes }
            let awake = sessions.reduce(0) { $0 + $1.awakeMinutes }
            let core = sessions.reduce(0) { $0 + $1.coreMinutes }
            let deep = sessions.reduce(0) { $0 + $1.deepMinutes }
            let rem = sessions.reduce(0) { $0 + $1.remMinutes }
            let asleep = core + deep + rem
            var row = DailyMetricRow(day: day, metric: AmachMetric.sleepId, total: asleep,
                                     count: sessions.reduce(0) { $0 + $1.samples.count }, source: .healthKit, updatedAt: now)
            row.sleepInBedMin = inBed
            row.sleepAwakeMin = awake
            row.sleepCoreMin = core
            row.sleepDeepMin = deep
            row.sleepRemMin = rem
            row.sleepEfficiency = inBed > 0 ? asleep / inBed : nil
            return row
        }
    }

    /// Single-source convenience for tests and older callers.
    nonisolated static func sleepRows(_ samples: [(end: Date, start: Date, value: Int)], now: Date = Date()) -> [DailyMetricRow] {
        sleepRows(samples.map { SleepSample(start: $0.start, end: $0.end, value: $0.value, source: "test") }, now: now)
    }

    /// Sleep samples overlapping [range.lowerBound - 1 day, range.upperBound).
    nonisolated static func sleepSamples(store: HKHealthStore, range: Range<Date>) async -> [SleepSample] {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound.addingTimeInterval(-86_400),
                                                    end: range.upperBound, options: [])
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKCategorySample] ?? [])
            }
            store.execute(query)
        }
        return samples.map {
            SleepSample(start: $0.startDate, end: $0.endDate, value: $0.value,
                        source: $0.sourceRevision.source.bundleIdentifier)
        }
    }

    nonisolated static func durationRows(metric: String, items: [(String, Double)], now: Date = Date()) -> [DailyMetricRow] {
        Dictionary(grouping: items, by: \.0).map { day, list in
            DailyMetricRow(day: day, metric: metric, total: list.map(\.1).reduce(0, +),
                           count: list.count, source: .healthKit, updatedAt: now)
        }
    }

    // MARK: HealthKit query wrappers

    nonisolated private static func quantitySamples(store: HKHealthStore, type: HKQuantityType, range: Range<Date>) async -> [HKQuantitySample] {
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }

    nonisolated private static func dailySums(store: HKHealthStore, type: HKQuantityType, unit: HKUnit, range: Range<Date>) async -> [String: Double] {
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound, options: .strictStartDate)
        var interval = DateComponents()
        interval.day = 1
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum,
                anchorDate: Calendar.current.startOfDay(for: range.lowerBound), intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, _ in
                var out: [String: Double] = [:]
                collection?.enumerateStatistics(from: range.lowerBound, to: range.upperBound) { stats, _ in
                    if let sum = stats.sumQuantity()?.doubleValue(for: unit) {
                        out[stats.startDate.vaultDay] = sum
                    }
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    nonisolated private static func categorySamples(store: HKHealthStore, type: HKSampleType?, range: Range<Date>, byEnd: Bool) async -> [HKCategorySample] {
        guard let type else { return [] }
        // Sleep belongs to the day it ends, so look back a day and filter by end date.
        let start = byEnd ? range.lowerBound.addingTimeInterval(-86_400) : range.lowerBound
        let predicate = HKQuery.predicateForSamples(withStart: start, end: range.upperBound, options: [])
        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKCategorySample] ?? [])
            }
            store.execute(query)
        }
        return samples.filter { range.contains(byEnd ? $0.endDate : $0.startDate) }
    }

    nonisolated private static func workoutSamples(store: HKHealthStore, range: Range<Date>) async -> [HKWorkout] {
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound, end: range.upperBound, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKWorkout] ?? [])
            }
            store.execute(query)
        }
    }

    nonisolated private static func firstSampleDate(store: HKHealthStore, type: HKSampleType) async -> Date? {
        await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, _ in
                continuation.resume(returning: samples?.first?.startDate)
            }
            store.execute(query)
        }
    }

    struct AnchoredResult {
        let days: [String]
        let hadDeletions: Bool
        let newAnchor: HKQueryAnchor?
    }

    nonisolated private static func anchoredChanges(store: HKHealthStore, type: HKSampleType, since: Date, anchor: HKQueryAnchor?) async -> AnchoredResult? {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
        return await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor, limit: HKObjectQueryNoLimit) { _, added, deleted, newAnchor, error in
                guard error == nil else { continuation.resume(returning: nil); return }
                var days = Set<String>()
                for sample in added ?? [] {
                    days.insert(sample.startDate.vaultDay)
                    days.insert(sample.endDate.vaultDay)
                }
                continuation.resume(returning: AnchoredResult(days: Array(days), hadDeletions: !(deleted ?? []).isEmpty, newAnchor: newAnchor))
            }
            store.execute(query)
        }
    }
}
