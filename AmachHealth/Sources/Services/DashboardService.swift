// DashboardService.swift
// AmachHealth
//
// Fetches live HealthKit data for the dashboard:
// today's key metrics + daily trend data for 7/30/90-day periods

import Foundation
import HealthKit
import Combine

// MARK: - Dashboard Today Data

struct DashboardTodayData {
    var steps: Double = 0
    var activeCalories: Double = 0
    var exerciseMinutes: Double = 0
    var heartRateAvg: Double = 0
    var heartRateMin: Double = 0
    var heartRateMax: Double = 0
    var hrv: Double = 0
    var restingHeartRate: Double = 0
    var sleepHours: Double = 0
    var sleepEfficiency: Double? = nil
    var respiratoryRate: Double = 0
    var vo2Max: Double = 0
}

// MARK: - Trend Models

struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

enum TrendPeriod: String, CaseIterable {
    case week = "7D"
    case month = "30D"
    case threeMonths = "3M"

    var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .threeMonths: return 90
        }
    }
}

// MARK: - Dashboard Service

@MainActor
final class DashboardService: ObservableObject {
    static let shared = DashboardService()

    @Published var today = DashboardTodayData()
    @Published var stepsTrend: [TrendPeriod: [TrendPoint]] = [:]
    @Published var heartRateTrend: [TrendPeriod: [TrendPoint]] = [:]
    @Published var hrvTrend: [TrendPeriod: [TrendPoint]] = [:]
    @Published var sleepTrend: [TrendPeriod: [TrendPoint]] = [:]
    @Published var calsTrend: [TrendPeriod: [TrendPoint]] = [:]
    @Published var isLoading = false
    @Published var error: String?

    private var lastLoaded: Date?
    private let store = HKHealthStore()

    private init() {}

    func load(force: Bool = false) async {
        if !force, let last = lastLoaded, Date().timeIntervalSince(last) < 300 { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }

        isLoading = true
        error = nil

        async let todayFetch = fetchToday()
        async let stepsFetch = fetchAllPeriods(
            identifier: .stepCount,
            options: .cumulativeSum,
            unit: .count()
        )
        async let hrFetch = fetchAllPeriods(
            identifier: .heartRate,
            options: .discreteAverage,
            unit: HKUnit.count().unitDivided(by: .minute())
        )
        async let hrvFetch = fetchAllPeriods(
            identifier: .heartRateVariabilitySDNN,
            options: .discreteAverage,
            unit: .secondUnit(with: .milli)
        )
        async let calsFetch = fetchAllPeriods(
            identifier: .activeEnergyBurned,
            options: .cumulativeSum,
            unit: .kilocalorie()
        )
        async let sleepFetch = fetchSleepAllPeriods()

        today = await todayFetch
        stepsTrend = await stepsFetch
        heartRateTrend = await hrFetch
        hrvTrend = await hrvFetch
        calsTrend = await calsFetch
        sleepTrend = await sleepFetch

        isLoading = false
        lastLoaded = Date()
    }

    // MARK: - Today's Data

    private func fetchToday() async -> DashboardTodayData {
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let vo2Unit = HKUnit.literUnit(with: .milli)
            .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))

        async let steps = stat(.stepCount, start: startOfDay, end: now, opts: .cumulativeSum, unit: .count())
        async let cals = stat(.activeEnergyBurned, start: startOfDay, end: now, opts: .cumulativeSum, unit: .kilocalorie())
        async let exercise = stat(.appleExerciseTime, start: startOfDay, end: now, opts: .cumulativeSum, unit: .minute())
        async let hrAvg = stat(.heartRate, start: startOfDay, end: now, opts: .discreteAverage, unit: bpmUnit)
        async let hrMin = stat(.heartRate, start: startOfDay, end: now, opts: .discreteMin, unit: bpmUnit)
        async let hrMax = stat(.heartRate, start: startOfDay, end: now, opts: .discreteMax, unit: bpmUnit)
        async let hrv = stat(.heartRateVariabilitySDNN, start: startOfDay, end: now, opts: .discreteAverage, unit: .secondUnit(with: .milli))
        async let rhr = stat(.restingHeartRate, start: startOfDay, end: now, opts: .discreteMostRecent, unit: bpmUnit)
        async let rr = stat(.respiratoryRate, start: startOfDay, end: now, opts: .discreteAverage, unit: bpmUnit)
        async let vo2 = stat(.vo2Max, start: startOfDay, end: now, opts: .discreteMostRecent, unit: vo2Unit)
        async let sleep = fetchLastNightSleep()

        let (sleepHrs, sleepEff) = await sleep

        return DashboardTodayData(
            steps: await steps ?? 0,
            activeCalories: await cals ?? 0,
            exerciseMinutes: await exercise ?? 0,
            heartRateAvg: await hrAvg ?? 0,
            heartRateMin: await hrMin ?? 0,
            heartRateMax: await hrMax ?? 0,
            hrv: await hrv ?? 0,
            restingHeartRate: await rhr ?? 0,
            sleepHours: sleepHrs,
            sleepEfficiency: sleepEff,
            respiratoryRate: await rr ?? 0,
            vo2Max: await vo2 ?? 0
        )
    }

    // MARK: - Trend Fetching

    private func fetchAllPeriods(
        identifier: HKQuantityTypeIdentifier,
        options: HKStatisticsOptions,
        unit: HKUnit
    ) async -> [TrendPeriod: [TrendPoint]] {
        var result: [TrendPeriod: [TrendPoint]] = [:]
        for period in TrendPeriod.allCases {
            result[period] = await fetchDailyTrend(
                identifier: identifier,
                days: period.days,
                options: options,
                unit: unit
            )
        }
        return result
    }

    private func fetchSleepAllPeriods() async -> [TrendPeriod: [TrendPoint]] {
        var result: [TrendPeriod: [TrendPoint]] = [:]
        for period in TrendPeriod.allCases {
            result[period] = await fetchSleepDailyTrend(days: period.days)
        }
        return result
    }

    // MARK: - HealthKit Queries

    private func stat(
        _ identifier: HKQuantityTypeIdentifier,
        start: Date,
        end: Date,
        opts: HKStatisticsOptions,
        unit: HKUnit
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: opts) { _, stats, _ in
                guard let stats else { continuation.resume(returning: nil); return }
                var value: Double?
                if opts.contains(.cumulativeSum) {
                    value = stats.sumQuantity()?.doubleValue(for: unit)
                } else if opts.contains(.discreteAverage) {
                    value = stats.averageQuantity()?.doubleValue(for: unit)
                } else if opts.contains(.discreteMin) {
                    value = stats.minimumQuantity()?.doubleValue(for: unit)
                } else if opts.contains(.discreteMax) {
                    value = stats.maximumQuantity()?.doubleValue(for: unit)
                } else if opts.contains(.discreteMostRecent) {
                    value = stats.mostRecentQuantity()?.doubleValue(for: unit)
                }
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    private func fetchDailyTrend(
        identifier: HKQuantityTypeIdentifier,
        days: Int,
        options: HKStatisticsOptions,
        unit: HKUnit
    ) async -> [TrendPoint] {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [] }
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: now, options: .strictStartDate)
        let anchorDate = Calendar.current.startOfDay(for: now)
        var interval = DateComponents(); interval.day = 1

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: options,
                anchorDate: anchorDate,
                intervalComponents: interval
            )
            query.initialResultsHandler = { _, collection, _ in
                var points: [TrendPoint] = []
                collection?.enumerateStatistics(from: startDate, to: now) { stats, _ in
                    let value: Double?
                    if options.contains(.cumulativeSum) {
                        value = stats.sumQuantity()?.doubleValue(for: unit)
                    } else {
                        value = stats.averageQuantity()?.doubleValue(for: unit)
                    }
                    if let v = value, v > 0 {
                        points.append(TrendPoint(date: stats.startDate, value: v))
                    }
                }
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }

    private func fetchSleepDailyTrend(days: Int) async -> [TrendPoint] {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else { return [] }
        let now = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now)!
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: now, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: [])
                    return
                }
                // asleep values: 1=asleep, 3=core, 4=deep, 5=rem
                let asleepRawValues: Set<Int> = [1, 3, 4, 5]
                var byDay: [String: Double] = [:]
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"

                for sample in samples {
                    guard asleepRawValues.contains(sample.value) else { continue }
                    let key = formatter.string(from: sample.endDate)
                    let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
                    byDay[key, default: 0] += hours
                }

                var points: [TrendPoint] = []
                for dayOffset in 0..<days {
                    guard let day = Calendar.current.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
                    let key = formatter.string(from: day)
                    if let hours = byDay[key], hours > 0 {
                        points.append(TrendPoint(date: day, value: min(hours, 16)))
                    }
                }
                points.sort { $0.date < $1.date }
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }

    private func fetchLastNightSleep() async -> (hours: Double, efficiency: Double?) {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return (0, nil)
        }
        let now = Date()
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let windowStart = cal.date(bySettingHour: 18, minute: 0, second: 0, of: yesterday) ?? yesterday
        let windowEnd = cal.date(bySettingHour: 14, minute: 0, second: 0, of: now) ?? now
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: (0, nil))
                    return
                }
                let asleepRawValues: Set<Int> = [1, 3, 4, 5]
                var totalSleep: Double = 0
                var totalInBed: Double = 0

                for sample in samples {
                    let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
                    if asleepRawValues.contains(sample.value) {
                        totalSleep += hours
                    } else if sample.value == 0 { // inBed
                        totalInBed += hours
                    }
                }
                let efficiency = totalInBed > 0 ? totalSleep / totalInBed : nil
                continuation.resume(returning: (totalSleep, efficiency))
            }
            store.execute(query)
        }
    }
}
