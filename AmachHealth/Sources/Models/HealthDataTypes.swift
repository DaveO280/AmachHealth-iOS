// HealthDataTypes.swift
// AmachHealth
//
// Matches web app's health data types for API compatibility

import Foundation
import HealthKit

// MARK: - Health Data Point (matches TypeScript HealthDataPoint)

struct HealthDataPoint: Codable, Identifiable {
    var id: String { "\(metricType)_\(startDate.timeIntervalSince1970)" }

    let metricType: String
    let value: String
    let startDate: Date
    let endDate: Date
    let source: String?
    let device: String?

    enum CodingKeys: String, CodingKey {
        case metricType = "type"
        case value
        case startDate
        case endDate
        case source
        case device
    }
}

// MARK: - Daily Summary (matches AppleHealthStorjService)

struct DailySummary: Codable {
    var metrics: [String: MetricSummary]
    var sleep: SleepSummary?
}

struct MetricSummary: Codable {
    var total: Double?
    var avg: Double?
    var min: Double?
    var max: Double?
    var count: Int
}

struct SleepSummary: Codable {
    var total: Int      // Total sleep in minutes
    var inBed: Int
    var awake: Int
    var core: Int       // Light sleep
    var deep: Int
    var rem: Int
    var efficiency: Double?
}

// MARK: - Apple Health Manifest (matches web app)

struct AppleHealthManifest: Codable {
    let version: Int
    let exportDate: String
    let uploadDate: String
    let dateRange: DateRange
    let metricsPresent: [String]
    let completeness: CompletenessInfo
    let sources: SourceInfo

    struct DateRange: Codable {
        let start: String
        let end: String
    }

    struct CompletenessInfo: Codable {
        let score: Int
        let tier: String
        let coreComplete: Bool
        let daysCovered: Int
        let recordCount: Int
    }

    struct SourceInfo: Codable {
        let watch: Int
        let phone: Int
        let other: Int
    }
}

// MARK: - Attestation Types

enum HealthDataType: Int, Codable {
    case dexa = 0
    case bloodwork = 1
    case appleHealth = 2
    case cgm = 3
}

enum AttestationTier: String, Codable {
    case none = "NONE"
    case bronze = "BRONZE"
    case silver = "SILVER"
    case gold = "GOLD"

    var minScore: Int {
        switch self {
        case .none: return 0
        case .bronze: return 40
        case .silver: return 60
        case .gold: return 80
        }
    }
}

// MARK: - HealthKit Metric Mapping

enum HealthKitMetric: String, CaseIterable {
    // Core metrics (required for completeness)
    case stepCount = "HKQuantityTypeIdentifierStepCount"
    case heartRate = "HKQuantityTypeIdentifierHeartRate"
    case heartRateVariability = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
    case restingHeartRate = "HKQuantityTypeIdentifierRestingHeartRate"
    case sleepAnalysis = "HKCategoryTypeIdentifierSleepAnalysis"
    case activeEnergy = "HKQuantityTypeIdentifierActiveEnergyBurned"
    case exerciseTime = "HKQuantityTypeIdentifierAppleExerciseTime"
    case vo2Max = "HKQuantityTypeIdentifierVO2Max"
    case respiratoryRate = "HKQuantityTypeIdentifierRespiratoryRate"

    // Body measurements
    case bodyMass = "HKQuantityTypeIdentifierBodyMass"
    case bodyFatPercentage = "HKQuantityTypeIdentifierBodyFatPercentage"
    case leanBodyMass = "HKQuantityTypeIdentifierLeanBodyMass"
    case height = "HKQuantityTypeIdentifierHeight"
    case bodyMassIndex = "HKQuantityTypeIdentifierBodyMassIndex"
    case waistCircumference = "HKQuantityTypeIdentifierWaistCircumference"

    // Activity
    case distanceWalkingRunning = "HKQuantityTypeIdentifierDistanceWalkingRunning"
    case distanceCycling = "HKQuantityTypeIdentifierDistanceCycling"
    case distanceSwimming = "HKQuantityTypeIdentifierDistanceSwimming"
    case flightsClimbed = "HKQuantityTypeIdentifierFlightsClimbed"
    case standTime = "HKQuantityTypeIdentifierAppleStandTime"
    case moveTime = "HKQuantityTypeIdentifierAppleMoveTime"

    // Vitals
    case bloodPressureSystolic = "HKQuantityTypeIdentifierBloodPressureSystolic"
    case bloodPressureDiastolic = "HKQuantityTypeIdentifierBloodPressureDiastolic"
    case bloodOxygen = "HKQuantityTypeIdentifierOxygenSaturation"
    case bodyTemperature = "HKQuantityTypeIdentifierBodyTemperature"

    // Nutrition
    case dietaryEnergy = "HKQuantityTypeIdentifierDietaryEnergyConsumed"
    case dietaryProtein = "HKQuantityTypeIdentifierDietaryProtein"
    case dietaryCarbs = "HKQuantityTypeIdentifierDietaryCarbohydrates"
    case dietaryFat = "HKQuantityTypeIdentifierDietaryFatTotal"
    case dietaryFiber = "HKQuantityTypeIdentifierDietaryFiber"
    case dietarySugar = "HKQuantityTypeIdentifierDietarySugar"
    case dietaryWater = "HKQuantityTypeIdentifierDietaryWater"
    case dietaryCaffeine = "HKQuantityTypeIdentifierDietaryCaffeine"

    // Mindfulness
    case mindfulMinutes = "HKCategoryTypeIdentifierMindfulSession"

    // Workouts
    case workouts = "HKWorkoutTypeIdentifier"

    // MARK: - HealthKit Type Conversion

    var hkObjectType: HKObjectType? {
        switch self {
        case .sleepAnalysis:
            return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case .mindfulMinutes:
            return HKObjectType.categoryType(forIdentifier: .mindfulSession)
        case .workouts:
            return HKObjectType.workoutType()
        default:
            // Most are quantity types
            guard let identifier = HKQuantityTypeIdentifier(rawValue: self.rawValue) else {
                return nil
            }
            return HKObjectType.quantityType(forIdentifier: identifier)
        }
    }

    var isCore: Bool {
        switch self {
        case .stepCount, .heartRate, .heartRateVariability, .restingHeartRate,
             .sleepAnalysis, .activeEnergy, .exerciseTime, .vo2Max, .respiratoryRate:
            return true
        default:
            return false
        }
    }

    // Unit for display/conversion
    var defaultUnit: HKUnit? {
        switch self {
        case .stepCount, .flightsClimbed:
            return .count()
        case .heartRate, .restingHeartRate, .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariability:
            return .secondUnit(with: .milli)
        case .activeEnergy, .dietaryEnergy:
            return .kilocalorie()
        case .exerciseTime, .standTime, .moveTime:
            return .minute()
        case .vo2Max:
            return HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .minute()))
        case .bodyMass:
            return .gramUnit(with: .kilo)
        case .bodyFatPercentage, .bloodOxygen:
            return .percent()
        case .height:
            return .meter()
        case .distanceWalkingRunning, .distanceCycling, .distanceSwimming:
            return .meter()
        case .bloodPressureSystolic, .bloodPressureDiastolic:
            return .millimeterOfMercury()
        case .bodyTemperature:
            return .degreeCelsius()
        case .dietaryProtein, .dietaryCarbs, .dietaryFat, .dietaryFiber, .dietarySugar:
            return .gram()
        case .dietaryWater:
            return .liter()
        case .dietaryCaffeine:
            return .gramUnit(with: .milli)
        default:
            return nil
        }
    }
}

// MARK: - Convenience Extensions

extension Date {
    var dateKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }
}
