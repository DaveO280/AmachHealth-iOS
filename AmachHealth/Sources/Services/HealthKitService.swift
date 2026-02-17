// HealthKitService.swift
// AmachHealth
//
// Core HealthKit integration service for reading health data

import Foundation
import HealthKit
import Combine

// MARK: - HealthKit Service

@MainActor
final class HealthKitService: ObservableObject {
    static let shared = HealthKitService()

    private let healthStore = HKHealthStore()

    @Published var isAuthorized = false
    @Published var authorizationError: String?
    @Published var isLoading = false

    // All metric types we want to read
    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        for metric in HealthKitMetric.allCases {
            if let type = metric.hkObjectType {
                types.insert(type)
            }
        }
        return types
    }

    private init() {}

    // MARK: - Authorization

    var isHealthKitAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async throws {
        guard isHealthKitAvailable else {
            throw HealthKitError.notAvailable
        }

        do {
            // Request read-only access (we don't write data)
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            authorizationError = nil
        } catch {
            authorizationError = error.localizedDescription
            throw HealthKitError.authorizationFailed(error)
        }
    }

    // MARK: - Data Fetching

    /// Fetch all health data for a date range
    func fetchAllHealthData(
        from startDate: Date,
        to endDate: Date,
        onProgress: ((Double, String) -> Void)? = nil
    ) async throws -> [String: [HealthDataPoint]] {
        isLoading = true
        defer { isLoading = false }

        var allData: [String: [HealthDataPoint]] = [:]
        let metrics = HealthKitMetric.allCases
        let total = Double(metrics.count)

        for (index, metric) in metrics.enumerated() {
            let progress = Double(index) / total
            onProgress?(progress, "Fetching \(metric.rawValue.components(separatedBy: "Identifier").last ?? metric.rawValue)...")

            do {
                let points = try await fetchMetric(metric, from: startDate, to: endDate)
                if !points.isEmpty {
                    allData[metric.rawValue] = points
                }
            } catch {
                // Log but continue - some metrics may not have data
                print("⚠️ Failed to fetch \(metric.rawValue): \(error.localizedDescription)")
            }
        }

        onProgress?(1.0, "Complete!")
        return allData
    }

    /// Fetch a single metric type
    func fetchMetric(
        _ metric: HealthKitMetric,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [HealthDataPoint] {
        guard let objectType = metric.hkObjectType else {
            return []
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )

        switch metric {
        case .sleepAnalysis:
            return try await fetchCategorySamples(
                type: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
                predicate: predicate,
                metricType: metric.rawValue
            )
        case .mindfulMinutes:
            return try await fetchCategorySamples(
                type: HKObjectType.categoryType(forIdentifier: .mindfulSession)!,
                predicate: predicate,
                metricType: metric.rawValue
            )
        case .workouts:
            return try await fetchWorkouts(predicate: predicate)
        default:
            guard let quantityType = objectType as? HKQuantityType,
                  let unit = metric.defaultUnit else {
                return []
            }
            return try await fetchQuantitySamples(
                type: quantityType,
                unit: unit,
                predicate: predicate,
                metricType: metric.rawValue
            )
        }
    }

    // MARK: - Private Fetch Methods

    private func fetchQuantitySamples(
        type: HKQuantityType,
        unit: HKUnit,
        predicate: NSPredicate,
        metricType: String
    ) async throws -> [HealthDataPoint] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let points = (samples as? [HKQuantitySample] ?? []).map { sample in
                    HealthDataPoint(
                        metricType: metricType,
                        value: String(sample.quantity.doubleValue(for: unit)),
                        startDate: sample.startDate,
                        endDate: sample.endDate,
                        source: sample.sourceRevision.source.name,
                        device: sample.device?.name
                    )
                }

                continuation.resume(returning: points)
            }

            healthStore.execute(query)
        }
    }

    private func fetchCategorySamples(
        type: HKCategoryType,
        predicate: NSPredicate,
        metricType: String
    ) async throws -> [HealthDataPoint] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let points = (samples as? [HKCategorySample] ?? []).map { sample in
                    // For sleep, convert the category value to stage name
                    let value: String
                    if type.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
                        value = self.sleepStageFromValue(sample.value)
                    } else {
                        value = String(sample.value)
                    }

                    return HealthDataPoint(
                        metricType: metricType,
                        value: value,
                        startDate: sample.startDate,
                        endDate: sample.endDate,
                        source: sample.sourceRevision.source.name,
                        device: sample.device?.name
                    )
                }

                continuation.resume(returning: points)
            }

            healthStore.execute(query)
        }
    }

    private func fetchWorkouts(predicate: NSPredicate) async throws -> [HealthDataPoint] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let points = (samples as? [HKWorkout] ?? []).map { workout in
                    HealthDataPoint(
                        metricType: "HKWorkoutTypeIdentifier",
                        value: workout.workoutActivityType.name,
                        startDate: workout.startDate,
                        endDate: workout.endDate,
                        source: workout.sourceRevision.source.name,
                        device: workout.device?.name
                    )
                }

                continuation.resume(returning: points)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Sleep Stage Mapping

    private func sleepStageFromValue(_ value: Int) -> String {
        // Match web app's sleep stage values
        switch value {
        case 0: return "inBed"
        case 1: return "asleep"  // Unspecified asleep
        case 2: return "awake"
        case 3: return "core"    // Core/light sleep
        case 4: return "deep"
        case 5: return "rem"
        default: return "core"
        }
    }

    // MARK: - Aggregation (matches web app's AppleHealthStorjService)

    func buildDailySummaries(
        from data: [String: [HealthDataPoint]]
    ) -> [String: DailySummary] {
        var summaries: [String: DailySummary] = [:]

        for (metricType, points) in data {
            let metric = HealthKitMetric(rawValue: metricType)

            // Special handling for sleep
            if metricType == HealthKitMetric.sleepAnalysis.rawValue {
                aggregateSleepData(points: points, into: &summaries)
                continue
            }

            // Group by date
            let byDate = Dictionary(grouping: points) { $0.startDate.dateKey }

            for (dateKey, dayPoints) in byDate {
                if summaries[dateKey] == nil {
                    summaries[dateKey] = DailySummary(metrics: [:], sleep: nil)
                }

                let values = dayPoints.compactMap { Double($0.value) }
                guard !values.isEmpty else { continue }

                let metricKey = normalizeMetricKey(metricType)
                let summary = aggregateValues(values, for: metric)
                summaries[dateKey]?.metrics[metricKey] = summary
            }
        }

        return summaries
    }

    private func aggregateSleepData(
        points: [HealthDataPoint],
        into summaries: inout [String: DailySummary]
    ) {
        // Group by END date (when you wake up)
        let byDate = Dictionary(grouping: points) { $0.endDate.dateKey }

        for (dateKey, dayPoints) in byDate {
            if summaries[dateKey] == nil {
                summaries[dateKey] = DailySummary(metrics: [:], sleep: nil)
            }

            var sleep = SleepSummary(total: 0, inBed: 0, awake: 0, core: 0, deep: 0, rem: 0, efficiency: nil)

            for point in dayPoints {
                let durationMin = Int(point.endDate.timeIntervalSince(point.startDate) / 60)
                let stage = point.value.lowercased()

                if stage.contains("inbed") || stage == "0" {
                    sleep.inBed += durationMin
                } else if stage.contains("awake") || stage == "2" {
                    sleep.awake += durationMin
                } else if stage.contains("core") || stage == "3" {
                    sleep.core += durationMin
                    sleep.total += durationMin
                } else if stage.contains("deep") || stage == "4" {
                    sleep.deep += durationMin
                    sleep.total += durationMin
                } else if stage.contains("rem") || stage == "5" {
                    sleep.rem += durationMin
                    sleep.total += durationMin
                } else if stage.contains("asleep") || stage == "1" {
                    sleep.core += durationMin  // Generic asleep -> core
                    sleep.total += durationMin
                }
            }

            if sleep.inBed > 0 {
                sleep.efficiency = Double(sleep.total) / Double(sleep.inBed)
            }

            summaries[dateKey]?.sleep = sleep
        }
    }

    private func aggregateValues(_ values: [Double], for metric: HealthKitMetric?) -> MetricSummary {
        let sum = values.reduce(0, +)
        let avg = sum / Double(values.count)
        let min = values.min() ?? 0
        let max = values.max() ?? 0

        // Determine aggregation type based on metric
        switch metric {
        case .stepCount, .flightsClimbed, .activeEnergy, .exerciseTime,
             .distanceWalkingRunning, .distanceCycling, .distanceSwimming:
            // Sum-based metrics
            return MetricSummary(total: sum, avg: nil, min: nil, max: nil, count: values.count)

        case .heartRate, .heartRateVariability, .restingHeartRate,
             .respiratoryRate, .bloodOxygen, .bodyTemperature:
            // Average with min/max
            return MetricSummary(total: nil, avg: avg, min: min, max: max, count: values.count)

        default:
            // Default to average
            return MetricSummary(total: nil, avg: avg, min: nil, max: nil, count: values.count)
        }
    }

    private func normalizeMetricKey(_ metricType: String) -> String {
        // Remove HK prefix and convert to camelCase for cleaner keys
        metricType
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutTypeIdentifier", with: "workout")
    }

    // MARK: - Completeness Calculation

    func calculateCompleteness(
        metricsPresent: [String],
        startDate: Date,
        endDate: Date
    ) -> (score: Int, tier: AttestationTier, coreComplete: Bool, daysCovered: Int) {
        let coreMetrics = HealthKitMetric.allCases.filter { $0.isCore }.map { $0.rawValue }
        let corePresent = metricsPresent.filter { coreMetrics.contains($0) }

        let coreComplete = corePresent.count >= 7  // 7 of 9 core metrics
        let coreScore = (Double(corePresent.count) / Double(coreMetrics.count)) * 50

        let otherMetrics = metricsPresent.filter { !coreMetrics.contains($0) }
        let otherScore = min(30, Double(otherMetrics.count) * 2)  // Cap at 30%

        let daysCovered = Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        let daysScore = min(20, Double(daysCovered) / 90 * 20)  // 90+ days = 20%

        let totalScore = Int(coreScore + otherScore + daysScore)
        let tier: AttestationTier
        if totalScore >= 80 && coreComplete {
            tier = .gold
        } else if totalScore >= 60 && coreComplete {
            tier = .silver
        } else if totalScore >= 40 {
            tier = .bronze
        } else {
            tier = .none
        }

        return (totalScore, tier, coreComplete, daysCovered)
    }
}

// MARK: - Errors

enum HealthKitError: LocalizedError {
    case notAvailable
    case authorizationFailed(Error)
    case queryFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "HealthKit is not available on this device"
        case .authorizationFailed(let error):
            return "Failed to authorize HealthKit: \(error.localizedDescription)"
        case .queryFailed(let error):
            return "Failed to query health data: \(error.localizedDescription)"
        }
    }
}

// MARK: - Workout Activity Type Extension

extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .walking: return "Walking"
        case .swimming: return "Swimming"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength Training"
        case .traditionalStrengthTraining: return "Weight Training"
        case .crossTraining: return "Cross Training"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing: return "Stair Climbing"
        case .highIntensityIntervalTraining: return "HIIT"
        case .dance: return "Dance"
        case .pilates: return "Pilates"
        case .boxing: return "Boxing"
        case .kickboxing: return "Kickboxing"
        case .martialArts: return "Martial Arts"
        case .tennis: return "Tennis"
        case .badminton: return "Badminton"
        case .basketball: return "Basketball"
        case .soccer: return "Soccer"
        case .golf: return "Golf"
        default: return "Workout"
        }
    }
}
