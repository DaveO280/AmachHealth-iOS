// MockDataSeeder.swift
// AmachHealthTests
//
// Populates the iOS Simulator's HealthKit store with 60 days of realistic data
// so Luma can be exercised with a full context stack.
//
// Run via SeedHealthKitTests — see that file for the xcodebuild invocation.

import Foundation
import HealthKit

// MARK: - MockDataSeeder

/// Writes deterministic, realistic health data into the HealthKit store.
///
/// Anomaly windows (designed to trigger AnomalyDetector):
///   • Days 15–17  — HRV ↓22 ms, RHR ↑82 bpm  (overtraining/illness signal)
///   • Day  30     — Steps 22,000               (unusual activity spike)
///   • Days 45–46  — Sleep 4.5 hrs              (poor sleep cluster)
@MainActor
final class MockDataSeeder {

    private let store    = HKHealthStore()
    private let calendar = Calendar.current

    // MARK: - Public

    /// Seeds `days` days of data ending on `anchor` (defaults to today).
    func seed(days: Int = 60, endingOn anchor: Date = Date()) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("⚠️  HealthKit not available — must run on Simulator or device.")
            return
        }

        try await requestAuthorization()
        print("🌱 Seeding \(days) days of HealthKit data…")

        let endDay = calendar.startOfDay(for: anchor)
        var allSamples: [HKSample] = []

        for offset in 0..<days {
            // offset 0 = oldest day, offset (days-1) = anchor day
            let date = calendar.date(byAdding: .day, value: -(days - 1 - offset), to: endDay)!
            allSamples.append(contentsOf: buildDaySamples(date: date, dayIndex: offset, totalDays: days))
        }

        // Batch-save to avoid overloading HealthKit in one call.
        let batchSize = 80
        var saved = 0
        for batchStart in stride(from: 0, to: allSamples.count, by: batchSize) {
            let slice = Array(allSamples[batchStart..<min(batchStart + batchSize, allSamples.count)])
            try await store.save(slice)
            saved += slice.count
        }

        print("✅ Seeded \(saved) samples across \(days) days.")
    }

    // MARK: - Authorization

    private func requestAuthorization() async throws {
        let writeTypes: Set<HKSampleType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.heartRate),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.appleExerciseTime),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.bodyMass),
            HKQuantityType(.respiratoryRate),
            HKCategoryType(.sleepAnalysis),
        ]
        try await store.requestAuthorization(toShare: writeTypes, read: [])
    }

    // MARK: - Per-Day Sample Builder

    private func buildDaySamples(date: Date, dayIndex: Int, totalDays: Int) -> [HKSample] {
        // t: 0.0 (oldest) → 1.0 (most recent) — drives slow improvement trends
        let t = Double(dayIndex) / Double(max(totalDays - 1, 1))
        // Deterministic multi-frequency noise in -1.0...1.0
        let n = deterministicNoise(dayIndex)

        let weekday    = calendar.component(.weekday, from: date)  // 1=Sun…7=Sat
        let isWeekday  = weekday >= 2 && weekday <= 6
        let isActiveDay = isWeekday && (dayIndex % 7 < 4)          // ~3–4 active days/week

        var samples: [HKSample] = []

        // ── Steps (4 k–14 k/day; weekdays higher) ─────────────────────────────
        var steps = (isWeekday ? 8_500.0 : 6_500.0) + n * 3_200.0
        if dayIndex == 29 { steps = 22_000 }    // Day 30 spike anomaly
        samples.append(qty(.stepCount, value: clamp(steps, 2_500, 23_000), unit: .count(), at: noon(date)))

        // ── Resting HR (70→60 bpm over the period; anomaly days 15–17) ─────────
        var rhr = 70.0 - t * 10.0 + n * 4.0
        if dayIndex >= 14 && dayIndex <= 16 { rhr = 82.0 }
        samples.append(qty(.restingHeartRate, value: clamp(rhr, 50, 92), unit: .bpm, at: noon(date)))

        // ── HRV SDNN (38→58 ms; inverse to RHR; anomaly days 15–17) ────────────
        var hrv = 38.0 + t * 20.0 - n * 10.0
        if dayIndex >= 14 && dayIndex <= 16 { hrv = 22.0 }
        samples.append(qty(.heartRateVariabilitySDNN, value: clamp(hrv, 15, 80),
                           unit: .secondUnit(with: .milli), at: noon(date)))

        // ── Respiratory rate (13–17 breaths/min; elevated during anomaly) ──────
        var rr = 15.0 + n * 1.5
        if dayIndex >= 14 && dayIndex <= 16 { rr += 2.5 }
        samples.append(qty(.respiratoryRate, value: clamp(rr, 11, 21), unit: .bpm, at: noon(date)))

        // ── Active energy (200–800 kcal/day) ────────────────────────────────────
        let energy = clamp((isWeekday ? 480.0 : 360.0) + n * 200.0, 150, 900)
        samples.append(qty(.activeEnergyBurned, value: energy, unit: .kilocalorie(), at: noon(date)))

        // ── Exercise minutes (0–75/day; 3–4 active days/week) ────────────────────
        let exMins = isActiveDay ? clamp(42.0 + n * 22.0, 15, 75) : clamp(n * 5.0 + 3.0, 0, 10)
        samples.append(qty(.appleExerciseTime, value: exMins, unit: .minute(), at: noon(date)))

        // ── Weight (80→78 kg slow downward trend) ────────────────────────────────
        let weight = clamp(80.0 - t * 2.0 + n * 0.3, 77.0, 81.0)
        samples.append(qty(.bodyMass, value: weight, unit: .gramUnit(with: .kilo), at: noon(date)))

        // ── Sleep (6.0–8.5 hrs; anomaly days 45–46 → 4.5 hrs) ──────────────────
        var sleepHrs = clamp(7.2 + n * 0.9, 5.5, 9.0)
        if dayIndex == 44 || dayIndex == 45 { sleepHrs = 4.5 }
        samples.append(contentsOf: buildSleepSamples(date: date, totalHours: sleepHrs, noise: n))

        // ── HR scatter (12 samples/day for zone analysis) ────────────────────────
        samples.append(contentsOf: buildHRScatter(date: date, rhr: rhr, isActiveDay: isActiveDay, noise: n))

        return samples
    }

    // MARK: - Sleep Samples (iOS 17 stage breakdown)

    private func buildSleepSamples(date: Date, totalHours: Double, noise: Double) -> [HKSample] {
        let sleepType = HKCategoryType(.sleepAnalysis)

        // Sleep window begins 11 pm the night before the recorded date.
        let prevNight = calendar.date(byAdding: .day, value: -1, to: date)!
        let sleepStart = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: prevNight)!

        // Stage fractions — realistic distribution with slight daily variation.
        let deepFrac  = clamp(0.18 + noise * 0.04, 0.12, 0.24)   // 12–24 % deep (1–2 hrs)
        let remFrac   = clamp(0.22 + noise * 0.05, 0.15, 0.28)   // 15–28 % REM  (1.5–2.5 hrs)
        let awakeFrac = 0.06                                        // 6 % awake
        let coreFrac  = 1.0 - deepFrac - remFrac - awakeFrac

        var cursor = sleepStart
        var samples: [HKSample] = []

        func stage(_ value: HKCategoryValueSleepAnalysis, hours: Double) {
            guard hours > 0.01 else { return }
            let end = cursor.addingTimeInterval(hours * 3_600)
            samples.append(HKCategorySample(
                type: sleepType,
                value: value.rawValue,
                start: cursor,
                end: end
            ))
            cursor = end
        }

        // Realistic layout: light → deep → light → REM → brief wake
        stage(.asleepCore, hours: totalHours * coreFrac * 0.55)
        stage(.asleepDeep, hours: totalHours * deepFrac)
        stage(.asleepCore, hours: totalHours * coreFrac * 0.45)
        stage(.asleepREM,  hours: totalHours * remFrac)
        stage(.awake,      hours: totalHours * awakeFrac)

        return samples
    }

    // MARK: - HR Scatter Samples

    private func buildHRScatter(date: Date, rhr: Double, isActiveDay: Bool, noise: Double) -> [HKQuantitySample] {
        let hrType = HKQuantityType(.heartRate)
        // Sample at representative hours throughout the day.
        let hours = [7, 9, 11, 13, 15, 17, 18, 19, 20, 22, 6, 3]

        return hours.compactMap { hour -> HKQuantitySample? in
            let hr: Double
            switch hour {
            case 17...19 where isActiveDay:
                hr = clamp(rhr + 60.0 + noise * 15.0, rhr + 35, 178)   // exercise
            case 22, 3, 6:
                hr = clamp(rhr - 6.0 + noise * 3.0, 42, rhr + 2)       // sleep
            default:
                hr = clamp(rhr + 14.0 + noise * 12.0, rhr, 125)         // daily activity
            }
            // Spread minute offsets deterministically so samples don't stack on :00.
            let minute = abs((hour * 7 + Int(noise * 10)) % 60)
            guard let t = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) else { return nil }
            return HKQuantitySample(
                type: hrType,
                quantity: HKQuantity(unit: .bpm, doubleValue: hr),
                start: t,
                end: t
            )
        }
    }

    // MARK: - Utility

    private func qty(
        _ id: HKQuantityTypeIdentifier,
        value: Double,
        unit: HKUnit,
        at date: Date
    ) -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(id),
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: date,
            end: date
        )
    }

    private func noon(_ date: Date) -> Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)!
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        max(lo, min(hi, v))
    }

    /// Deterministic noise in -1.0...1.0 — three overlapping sine waves.
    /// Same day always returns the same value across seeder runs.
    private func deterministicNoise(_ day: Int) -> Double {
        let d = Double(day)
        return sin(d * 0.61803) * 0.50
             + sin(d * 1.41421 + 1.10) * 0.30
             + sin(d * 2.71828 + 2.20) * 0.20
    }
}

// MARK: - HKUnit convenience

private extension HKUnit {
    /// count/min — used for heart rate, resting HR, and respiratory rate.
    static var bpm: HKUnit { .count().unitDivided(by: .minute()) }
}
