// DashboardService.swift
// AmachHealth
//
// Fetches live HealthKit data for the dashboard:
// today's key metrics + daily trend data for 7/30/90-day periods

import Foundation
import HealthKit
import Combine

// MARK: - Heart Rate Zones (today)
//
// Zones are based on % of estimated max HR (default 185 bpm ≈ 220−35).
// Time is computed by interpolating gaps between consecutive HR samples.
//
// Zone 1 — Recovery  < 60%   warm-up, easy movement
// Zone 2 — Fat Burn  60–70%  aerobic base
// Zone 3 — Aerobic   70–80%  steady cardio
// Zone 4 — Threshold 80–90%  hard effort
// Zone 5 — Peak      > 90%   max effort / sprint

struct HeartRateZoneMinutes {
    var zone1: Double = 0
    var zone2: Double = 0
    var zone3: Double = 0
    var zone4: Double = 0
    var zone5: Double = 0
    var estimatedMaxHR: Double = 185

    var total: Double { zone1 + zone2 + zone3 + zone4 + zone5 }

    func fraction(for zone: Int) -> Double {
        guard total > 0 else { return 0 }
        switch zone {
        case 1: return zone1 / total
        case 2: return zone2 / total
        case 3: return zone3 / total
        case 4: return zone4 / total
        case 5: return zone5 / total
        default: return 0
        }
    }

    func minutes(for zone: Int) -> Double {
        switch zone {
        case 1: return zone1
        case 2: return zone2
        case 3: return zone3
        case 4: return zone4
        case 5: return zone5
        default: return 0
        }
    }
}

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
    var sleepStages: SleepStageBreakdown = SleepStageBreakdown()
    var respiratoryRate: Double = 0
    var vo2Max: Double = 0
}

// MARK: - Sleep Stage Breakdown (last night)

struct SleepStageBreakdown {
    var coreMinutes: Int = 0     // Light sleep (NREM 1/2)
    var deepMinutes: Int = 0     // Deep sleep (NREM 3)
    var remMinutes: Int = 0      // REM sleep
    var awakeMinutes: Int = 0    // Awake during sleep window
    var efficiency: Double? = nil

    var totalSleepMinutes: Int { coreMinutes + deepMinutes + remMinutes }
    var totalSleepHours: Double { Double(totalSleepMinutes) / 60.0 }
}

// MARK: - Trend Models

struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct SleepStageTrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let coreHours: Double
    let deepHours: Double
    let remHours: Double
    let awakeHours: Double

    var totalHours: Double { coreHours + deepHours + remHours }
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
    @Published var sleepStagesTrend: [TrendPeriod: [SleepStageTrendPoint]] = [:]
    @Published var calsTrend: [TrendPeriod: [TrendPoint]] = [:]
    @Published var rhrTrend: [TrendPeriod: [TrendPoint]] = [:]
    @Published var vo2Trend: [TrendPeriod: [TrendPoint]] = [:]
    @Published var rrTrend: [TrendPeriod: [TrendPoint]] = [:]
    @Published var todayHRZones = HeartRateZoneMinutes()
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
        async let sleepStagesFetch = fetchSleepStagesAllPeriods()
        async let rhrFetch = fetchAllPeriods(
            identifier: .restingHeartRate,
            options: .discreteAverage,
            unit: HKUnit.count().unitDivided(by: .minute())
        )
        async let rrFetch = fetchAllPeriods(
            identifier: .respiratoryRate,
            options: .discreteAverage,
            unit: HKUnit.count().unitDivided(by: .minute())
        )
        async let vo2Fetch = fetchAllPeriods(
            identifier: .vo2Max,
            options: .discreteAverage,
            unit: HKUnit.literUnit(with: .milli)
                .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        )

        async let hrZonesFetch = fetchTodayHRZones()

        today = await todayFetch
        stepsTrend = await stepsFetch
        heartRateTrend = await hrFetch
        hrvTrend = await hrvFetch
        calsTrend = await calsFetch
        sleepTrend = await sleepFetch
        sleepStagesTrend = await sleepStagesFetch
        rhrTrend = await rhrFetch
        rrTrend = await rrFetch
        vo2Trend = await vo2Fetch
        todayHRZones = await hrZonesFetch

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
        async let rhr = stat(.restingHeartRate, start: startOfDay, end: now, opts: .mostRecent, unit: bpmUnit)
        async let rr = stat(.respiratoryRate, start: startOfDay, end: now, opts: .discreteAverage, unit: bpmUnit)
        async let vo2 = stat(.vo2Max, start: startOfDay, end: now, opts: .mostRecent, unit: vo2Unit)
        async let sleep = fetchLastNightSleep()

        let (sleepHrs, sleepEff, sleepStages) = await sleep

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
            sleepStages: sleepStages,
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
                } else if opts.contains(.mostRecent) {
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

    private func fetchLastNightSleep() async -> (hours: Double, efficiency: Double?, stages: SleepStageBreakdown) {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return (0, nil, SleepStageBreakdown())
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
                    continuation.resume(returning: (0, nil, SleepStageBreakdown()))
                    return
                }
                var totalSleep: Double = 0
                var totalInBed: Double = 0
                var stages = SleepStageBreakdown()

                for sample in samples {
                    let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
                    let mins = Int(hours * 60)
                    switch sample.value {
                    case 0:  // inBed
                        totalInBed += hours
                    case 1:  // asleepUnspecified → count as core
                        totalSleep += hours
                        stages.coreMinutes += mins
                    case 2:  // awake during sleep window
                        stages.awakeMinutes += mins
                    case 3:  // asleepCore
                        totalSleep += hours
                        stages.coreMinutes += mins
                    case 4:  // asleepDeep
                        totalSleep += hours
                        stages.deepMinutes += mins
                    case 5:  // asleepREM
                        totalSleep += hours
                        stages.remMinutes += mins
                    default:
                        break
                    }
                }
                let efficiency = totalInBed > 0 ? totalSleep / totalInBed : nil
                stages.efficiency = efficiency
                continuation.resume(returning: (totalSleep, efficiency, stages))
            }
            store.execute(query)
        }
    }

    private func fetchSleepStagesAllPeriods() async -> [TrendPeriod: [SleepStageTrendPoint]] {
        var result: [TrendPeriod: [SleepStageTrendPoint]] = [:]
        for period in TrendPeriod.allCases {
            result[period] = await fetchSleepStagesDailyTrend(days: period.days)
        }
        return result
    }

    private func fetchSleepStagesDailyTrend(days: Int) async -> [SleepStageTrendPoint] {
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

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"

                var coreByDay: [String: Double] = [:]
                var deepByDay: [String: Double] = [:]
                var remByDay: [String: Double] = [:]
                var awakeByDay: [String: Double] = [:]

                for sample in samples {
                    let key = formatter.string(from: sample.endDate)
                    let hours = sample.endDate.timeIntervalSince(sample.startDate) / 3600
                    switch sample.value {
                    case 1, 3:  coreByDay[key, default: 0] += hours   // unspecified + core
                    case 2:     awakeByDay[key, default: 0] += hours
                    case 4:     deepByDay[key, default: 0] += hours
                    case 5:     remByDay[key, default: 0] += hours
                    default:    break
                    }
                }

                var points: [SleepStageTrendPoint] = []
                for dayOffset in 0..<days {
                    guard let day = Calendar.current.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
                    let key = formatter.string(from: day)
                    let core = coreByDay[key] ?? 0
                    let deep = deepByDay[key] ?? 0
                    let rem = remByDay[key] ?? 0
                    let awake = awakeByDay[key] ?? 0
                    if core + deep + rem > 0 {
                        points.append(SleepStageTrendPoint(
                            date: day,
                            coreHours: core,
                            deepHours: deep,
                            remHours: rem,
                            awakeHours: awake
                        ))
                    }
                }
                points.sort { $0.date < $1.date }
                continuation.resume(returning: points)
            }
            store.execute(query)
        }
    }

    // MARK: - Heart Rate Zones (today)

    private func fetchTodayHRZones() async -> HeartRateZoneMinutes {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return HeartRateZoneMinutes()
        }
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now, options: .strictStartDate)
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, _ in
                guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                    continuation.resume(returning: HeartRateZoneMinutes())
                    return
                }

                let maxHR: Double = 185   // ~220 − 35 default; refine with user age later
                var zones = HeartRateZoneMinutes(estimatedMaxHR: maxHR)

                // Interpolate time between consecutive samples (cap at 5 min to avoid gaps)
                for i in 0..<samples.count {
                    let bpm = samples[i].quantity.doubleValue(for: bpmUnit)
                    let nextStart = i + 1 < samples.count ? samples[i + 1].startDate : samples[i].endDate
                    let rawSeconds = nextStart.timeIntervalSince(samples[i].startDate)
                    let minutes = min(rawSeconds, 300) / 60  // cap at 5 min

                    let pct = bpm / maxHR
                    switch pct {
                    case ..<0.60:          zones.zone1 += max(minutes, 1.0 / 60)
                    case 0.60..<0.70:      zones.zone2 += max(minutes, 1.0 / 60)
                    case 0.70..<0.80:      zones.zone3 += max(minutes, 1.0 / 60)
                    case 0.80..<0.90:      zones.zone4 += max(minutes, 1.0 / 60)
                    default:               zones.zone5 += max(minutes, 1.0 / 60)
                    }
                }
                continuation.resume(returning: zones)
            }
            store.execute(query)
        }
    }
}
