// AmachMetric.swift
// AmachHealth
//
// The protocol's metric vocabulary for daily_metrics. Ids and units are
// Amach's, not HealthKit's: HealthKit is one source among several, and the
// web and older iOS payloads used their own keys. See SCHEMA.md.

import Foundation
import HealthKit

struct AmachMetric: Hashable {
    enum Aggregation: String {
        /// Daily total in `total` (steps, energy, distance, minutes).
        case sum
        /// Daily mean in `avg`, with `min`/`max` (heart rate, HRV).
        case range
        /// Daily mean in `avg` (body mass, VO2 max).
        case average
    }

    let id: String
    let unit: String
    let aggregation: Aggregation
    /// HealthKit quantity identifier, when HealthKit can supply it.
    let healthKit: HKQuantityTypeIdentifier?
    /// HealthKit unit that yields `unit` after `healthKitScale` is applied.
    let healthKitUnit: HKUnit?
    let healthKitScale: Double
    /// Keys used in older payloads (iOS "StepCount", web "stepCount"), lowercased.
    let legacyKeys: [String]

    init(
        _ id: String,
        unit: String,
        _ aggregation: Aggregation,
        hk: HKQuantityTypeIdentifier? = nil,
        hkUnit: HKUnit? = nil,
        scale: Double = 1,
        legacy: [String]
    ) {
        self.id = id
        self.unit = unit
        self.aggregation = aggregation
        self.healthKit = hk
        self.healthKitUnit = hkUnit
        self.healthKitScale = scale
        self.legacyKeys = legacy.map { $0.lowercased() }
    }

    // Special rows that aren't plain quantities.
    static let sleepId = "sleep"
    static let workoutMinutesId = "workout_minutes"
    static let mindfulMinutesId = "mindful_minutes"

    private static let bpm = HKUnit.count().unitDivided(by: .minute())

    static let all: [AmachMetric] = [
        // Activity (sums)
        AmachMetric("steps", unit: "count", .sum, hk: .stepCount, hkUnit: .count(), legacy: ["StepCount"]),
        AmachMetric("active_energy", unit: "kcal", .sum, hk: .activeEnergyBurned, hkUnit: .kilocalorie(), legacy: ["ActiveEnergyBurned"]),
        AmachMetric("basal_energy", unit: "kcal", .sum, hk: .basalEnergyBurned, hkUnit: .kilocalorie(), legacy: ["BasalEnergyBurned"]),
        AmachMetric("exercise_minutes", unit: "min", .sum, hk: .appleExerciseTime, hkUnit: .minute(), legacy: ["AppleExerciseTime"]),
        AmachMetric("stand_minutes", unit: "min", .sum, hk: .appleStandTime, hkUnit: .minute(), legacy: ["AppleStandTime"]),
        AmachMetric("move_minutes", unit: "min", .sum, hk: .appleMoveTime, hkUnit: .minute(), legacy: ["AppleMoveTime"]),
        AmachMetric("flights_climbed", unit: "count", .sum, hk: .flightsClimbed, hkUnit: .count(), legacy: ["FlightsClimbed"]),
        AmachMetric("distance_walking_running", unit: "m", .sum, hk: .distanceWalkingRunning, hkUnit: .meter(), legacy: ["DistanceWalkingRunning"]),
        AmachMetric("distance_cycling", unit: "m", .sum, hk: .distanceCycling, hkUnit: .meter(), legacy: ["DistanceCycling"]),
        AmachMetric("distance_swimming", unit: "m", .sum, hk: .distanceSwimming, hkUnit: .meter(), legacy: ["DistanceSwimming"]),
        AmachMetric("time_in_daylight", unit: "min", .sum, hk: .timeInDaylight, hkUnit: .minute(), legacy: ["TimeInDaylight"]),

        // Heart and breathing (ranges)
        AmachMetric("heart_rate", unit: "bpm", .range, hk: .heartRate, hkUnit: bpm, legacy: ["HeartRate"]),
        AmachMetric("hrv_sdnn", unit: "ms", .range, hk: .heartRateVariabilitySDNN, hkUnit: .secondUnit(with: .milli), legacy: ["HeartRateVariabilitySDNN"]),
        AmachMetric("respiratory_rate", unit: "breaths/min", .range, hk: .respiratoryRate, hkUnit: bpm, legacy: ["RespiratoryRate"]),
        AmachMetric("blood_oxygen", unit: "%", .range, hk: .oxygenSaturation, hkUnit: .percent(), scale: 100, legacy: ["OxygenSaturation"]),
        AmachMetric("body_temperature", unit: "degC", .range, hk: .bodyTemperature, hkUnit: .degreeCelsius(), legacy: ["BodyTemperature"]),
        AmachMetric("blood_glucose", unit: "mg/dL", .range, hk: .bloodGlucose,
                    hkUnit: HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci)), legacy: ["BloodGlucose"]),

        // Once-a-day style values (averages)
        AmachMetric("resting_heart_rate", unit: "bpm", .average, hk: .restingHeartRate, hkUnit: bpm, legacy: ["RestingHeartRate"]),
        AmachMetric("walking_heart_rate", unit: "bpm", .average, hk: .walkingHeartRateAverage, hkUnit: bpm, legacy: ["WalkingHeartRateAverage"]),
        AmachMetric("vo2_max", unit: "mL/kg/min", .average, hk: .vo2Max,
                    hkUnit: HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())),
                    legacy: ["VO2Max"]),
        AmachMetric("body_mass", unit: "kg", .average, hk: .bodyMass, hkUnit: .gramUnit(with: .kilo), legacy: ["BodyMass"]),
        AmachMetric("lean_body_mass", unit: "kg", .average, hk: .leanBodyMass, hkUnit: .gramUnit(with: .kilo), legacy: ["LeanBodyMass"]),
        AmachMetric("body_fat", unit: "%", .average, hk: .bodyFatPercentage, hkUnit: .percent(), scale: 100, legacy: ["BodyFatPercentage"]),
        AmachMetric("bmi", unit: "kg/m2", .average, hk: .bodyMassIndex, hkUnit: .count(), legacy: ["BodyMassIndex"]),
        AmachMetric("height", unit: "m", .average, hk: .height, hkUnit: .meter(), legacy: ["Height"]),
        AmachMetric("waist_circumference", unit: "cm", .average, hk: .waistCircumference, hkUnit: .meterUnit(with: .centi), legacy: ["WaistCircumference"]),
        AmachMetric("blood_pressure_systolic", unit: "mmHg", .range, hk: .bloodPressureSystolic, hkUnit: .millimeterOfMercury(), legacy: ["BloodPressureSystolic"]),
        AmachMetric("blood_pressure_diastolic", unit: "mmHg", .range, hk: .bloodPressureDiastolic, hkUnit: .millimeterOfMercury(), legacy: ["BloodPressureDiastolic"]),

        // Nutrition (sums)
        AmachMetric("dietary_energy", unit: "kcal", .sum, hk: .dietaryEnergyConsumed, hkUnit: .kilocalorie(), legacy: ["DietaryEnergyConsumed"]),
        AmachMetric("dietary_protein", unit: "g", .sum, hk: .dietaryProtein, hkUnit: .gram(), legacy: ["DietaryProtein"]),
        AmachMetric("dietary_carbohydrates", unit: "g", .sum, hk: .dietaryCarbohydrates, hkUnit: .gram(), legacy: ["DietaryCarbohydrates"]),
        AmachMetric("dietary_fat", unit: "g", .sum, hk: .dietaryFatTotal, hkUnit: .gram(), legacy: ["DietaryFatTotal"]),
        AmachMetric("dietary_fiber", unit: "g", .sum, hk: .dietaryFiber, hkUnit: .gram(), legacy: ["DietaryFiber"]),
        AmachMetric("dietary_sugar", unit: "g", .sum, hk: .dietarySugar, hkUnit: .gram(), legacy: ["DietarySugar"]),
        AmachMetric("dietary_water", unit: "mL", .sum, hk: .dietaryWater, hkUnit: .literUnit(with: .milli), legacy: ["DietaryWater"]),
        AmachMetric("dietary_caffeine", unit: "mg", .sum, hk: .dietaryCaffeine, hkUnit: .gramUnit(with: .milli), legacy: ["DietaryCaffeine"]),
    ]

    /// Non-quantity rows, listed so SCHEMA.md and imports share one vocabulary.
    static let specialUnits: [String: String] = [
        sleepId: "min",
        workoutMinutesId: "min",
        mindfulMinutesId: "min",
    ]

    static let byId: [String: AmachMetric] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    private static let byLegacyKey: [String: AmachMetric] = {
        var map: [String: AmachMetric] = [:]
        for metric in all {
            for key in metric.legacyKeys { map[key] = metric }
            map[metric.id] = metric
        }
        return map
    }()

    /// Resolve a payload key ("StepCount", "stepCount", "HKQuantityTypeIdentifierStepCount").
    static func resolve(legacyKey: String) -> AmachMetric? {
        let stripped = legacyKey
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
        return byLegacyKey[stripped.lowercased()]
    }

    static func unit(for metricId: String) -> String? {
        byId[metricId]?.unit ?? specialUnits[metricId]
    }
}
