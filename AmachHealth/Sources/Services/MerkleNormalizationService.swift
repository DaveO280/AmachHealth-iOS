// MerkleNormalizationService.swift
// AmachHealth
//
// Xcode: keep OUT of the iOS app target unless you add a dedicated macOS/CLI target.
//
// Transforms raw HealthKit query results into normalized MerkleLeaf values.
// This service is the bridge between HealthKit and the Merkle tree builder.
//
// IMPORTANT: This service knows about HealthKit.
//            The MerkleTreeBuilder knows NOTHING about HealthKit.
//            Keep that boundary clean.
//
// Normalization rules are authoritative — they define the protocol spec.
// Any change here breaks existing commitments. Treat as immutable after v1 launch.

import Foundation
import HealthKit
import CryptoKit

// MARK: - Raw Input Types

/// A single sample read from HealthKit (health metric or workout).
struct HealthSample {
    let metricType: String      // e.g. "HKQuantityTypeIdentifierStepCount"
    let value: Double           // numeric value in canonical HK unit
    let unit: String            // HK unit string
    let startDate: Date
    let endDate: Date
    let sourceBundleID: String  // e.g. "com.apple.health", "com.apple.health.watchOS"
    let device: String?         // device model string if available
}

/// A workout session from HealthKit.
struct WorkoutSample {
    let workoutType: HKWorkoutActivityType
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval  // seconds
    let sourceBundleID: String
}

// MARK: - Normalized Daily Output

/// Fully normalized daily leaf data ready for serialization.
/// This is the intermediate form between HealthKit and the wire-format leaf.
///
/// Carries both the v1 fields and the v2 additions (VO2 max, body composition,
/// sleep stage breakdown). Either format can be produced via toMerkleLeaf()
/// (v1, 90 bytes, Poseidon3) or toAmachLeafV2() (v2, 124 bytes, Poseidon4).
/// New leaves are committed as v2 starting Spring Push Season One.
struct NormalizedDailyLeaf {
    let dayId: UInt32
    let date: Date              // midnight local of this day
    let timezone: TimeZone
    let walletAddress: Data     // 32-byte wallet address

    // ── v1 metrics ─────────────────────────────────────────
    let steps: UInt32
    let activeEnergy: UInt32   // kcal * 100
    let exerciseMins: UInt16
    let hrv: UInt16            // ms * 10, 0 if absent
    let restingHR: UInt16      // bpm * 10, 0 if absent
    let sleepMins: UInt16      // total sleep
    let workoutCount: UInt8
    let sourceCount: UInt8
    let dataFlags: UInt16      // v1 flags (low 16 bits)
    let sourceHash: Data       // 32 bytes

    let hrvPresent: Bool
    let restingHRPresent: Bool
    let bloodOxygenPresent: Bool

    // ── v2 additions ───────────────────────────────────────
    /// VO2 max × 10, 0 if absent (e.g. 42.5 mL/kg/min → 425).
    let vo2max: UInt16
    /// Weight in grams ÷ 10, 0 if absent (e.g. 78.00 kg → 7800; range 0..655.35 kg).
    let weight: UInt16
    /// Body fat percentage × 100, 0 if absent (e.g. 18.50% → 1850).
    let bodyFatPct: UInt16
    /// Lean body mass in grams ÷ 10, 0 if absent.
    let leanMass: UInt16
    /// Sleep stage breakdown in minutes. Sum should approximate sleepMins
    /// when stages are reported; the legitimacy script verifies the
    /// internal consistency C.5 check.
    let deepSleepMins: UInt16
    let remSleepMins: UInt16
    let lightSleepMins: UInt16
    let awakeMins: UInt16

    let vo2maxPresent: Bool
    let weightPresent: Bool
    let bodyFatPctPresent: Bool
    let leanMassPresent: Bool
    let sleepStagesPresent: Bool

    /// Expanded v2 dataFlags: low 16 bits mirror v1, upper bits encode the
    /// new presence indicators. See AmachLeafV2Flag for layout.
    var dataFlagsV2: UInt32 {
        var f = UInt32(dataFlags)
        if vo2maxPresent       { f |= AmachLeafV2Flag.vo2maxPresent.rawValue }
        if weightPresent       { f |= AmachLeafV2Flag.weightPresent.rawValue }
        if bodyFatPctPresent   { f |= AmachLeafV2Flag.bodyFatPctPresent.rawValue }
        if leanMassPresent     { f |= AmachLeafV2Flag.leanMassPresent.rawValue }
        if sleepStagesPresent {
            if deepSleepMins  > 0 { f |= AmachLeafV2Flag.deepSleepPresent.rawValue }
            if remSleepMins   > 0 { f |= AmachLeafV2Flag.remSleepPresent.rawValue }
            if lightSleepMins > 0 { f |= AmachLeafV2Flag.lightSleepPresent.rawValue }
            if awakeMins      > 0 { f |= AmachLeafV2Flag.awakeMinsPresent.rawValue }
        }
        return f
    }

    /// Convert to the legacy v1 MerkleLeaf (90 bytes, Poseidon3).
    /// Existing v1 commitments stay readable; new commitments use v2.
    func toMerkleLeaf() -> MerkleLeaf {
        let tzOffsetMinutes = Int16(timezone.secondsFromGMT() / 60)
        return MerkleLeaf(
            dayId: dayId,
            wallet: walletAddress,
            timezoneOffset: tzOffsetMinutes,
            steps: steps,
            activeEnergy: activeEnergy,
            exerciseMins: exerciseMins,
            hrv: hrv,
            restingHR: restingHR,
            sleepMins: sleepMins,
            workoutCount: workoutCount,
            sourceCount: sourceCount,
            dataFlags: dataFlags,
            sourceHash: sourceHash
        )
    }

    /// Convert to the v2 wire format (124 bytes, Poseidon4) for Spring Push
    /// Season One and beyond.
    func toAmachLeafV2() -> AmachLeafV2 {
        let tzOffsetMinutes = Int16(timezone.secondsFromGMT() / 60)
        return AmachLeafV2(
            wallet: walletAddress,
            dayId: dayId,
            timezoneOffset: tzOffsetMinutes,
            steps: steps,
            activeEnergy: activeEnergy,
            exerciseMins: exerciseMins,
            hrv: hrv,
            restingHR: restingHR,
            sleepMins: sleepMins,
            workoutCount: workoutCount,
            sourceCount: sourceCount,
            dataFlags: dataFlagsV2,
            vo2max: vo2max,
            weight: weight,
            bodyFatPct: bodyFatPct,
            leanMass: leanMass,
            deepSleepMins: deepSleepMins,
            remSleepMins: remSleepMins,
            lightSleepMins: lightSleepMins,
            awakeMins: awakeMins,
            sourceHash: sourceHash
        )
    }
}

// MARK: - Service

/// Normalizes 90-day HealthKit data windows into deterministic leaf arrays.
///
/// Usage:
/// ```swift
/// let service = MerkleNormalizationService(walletAddress: walletData)
/// let leaves = service.normalize(
///     samples: healthSamples,
///     workouts: workoutSamples,
///     restingHRSamples: rhrSamples,
///     start: startDate,
///     end: endDate,
///     timezone: .current
/// )
/// ```
final class MerkleNormalizationService {

    let walletAddress: Data  // 32-byte wallet

    init(walletAddress: Data) {
        precondition(walletAddress.count <= 32, "Wallet address must be 32 bytes or fewer")
        // Pad to 32 bytes (left-pad with zeros for EVM addresses)
        if walletAddress.count < 32 {
            self.walletAddress = Data(repeating: 0, count: 32 - walletAddress.count) + walletAddress
        } else {
            self.walletAddress = walletAddress
        }
    }

    // MARK: - Main Entry Point

    /// Normalize a window of HealthKit samples into sorted MerkleLeaf array.
    ///
    /// - Parameters:
    ///   - samples: All quantity/category samples for the window.
    ///   - workouts: All workout sessions for the window.
    ///   - restingHRSamples: Dedicated resting HR samples (HealthKit daily value).
    ///   - start: Start of the normalization window (inclusive).
    ///   - end: End of the normalization window (inclusive).
    ///   - timezone: The user's local timezone for day attribution.
    /// - Returns: Sorted array of normalized leaves (sorted ascending by dayId). Days with zero data are omitted.
    func normalize(
        samples: [HealthSample],
        workouts: [WorkoutSample],
        restingHRSamples: [HealthSample],
        start: Date,
        end: Date,
        timezone: TimeZone
    ) -> [NormalizedDailyLeaf] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone

        // Enumerate every calendar day in [start, end] window
        var leaves: [NormalizedDailyLeaf] = []
        var current = calendar.startOfDay(for: start)

        while current <= end {
            let dayStart = current
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }

            // Collect samples ending in this calendar day
            let daySamples = samples.filter { s in
                s.endDate >= dayStart && s.endDate < dayEnd
            }
            let dayWorkouts = workouts.filter { w in
                w.startDate >= dayStart && w.startDate < dayEnd
            }
            let dayRHR = restingHRSamples.filter { s in
                s.startDate >= dayStart && s.startDate < dayEnd
            }

            // Skip completely empty days
            if daySamples.isEmpty && dayWorkouts.isEmpty && dayRHR.isEmpty {
                current = dayEnd
                continue
            }

            // Normalize the day
            if let leaf = normalizeDay(
                dayStart: dayStart,
                daySamples: daySamples,
                dayWorkouts: dayWorkouts,
                dayRHRSamples: dayRHR,
                timezone: timezone,
                calendar: calendar
            ) {
                leaves.append(leaf)
            }

            current = dayEnd
        }

        // Sort ascending by dayId — required for deterministic Merkle tree
        return leaves.sorted { $0.dayId < $1.dayId }
    }

    // MARK: - Per-Day Normalization

    private func normalizeDay(
        dayStart: Date,
        daySamples: [HealthSample],
        dayWorkouts: [WorkoutSample],
        dayRHRSamples: [HealthSample],
        timezone: TimeZone,
        calendar: Calendar
    ) -> NormalizedDailyLeaf? {

        // Gather all source bundle IDs seen this day
        var allSourceIDs: Set<String> = []
        for s in daySamples { allSourceIDs.insert(s.sourceBundleID) }
        for w in dayWorkouts { allSourceIDs.insert(w.sourceBundleID) }

        // === Steps ===
        // Sum HKQuantityTypeIdentifierStepCount samples whose endDate falls in the day
        let stepSamples = daySamples.filter {
            $0.metricType == "HKQuantityTypeIdentifierStepCount"
        }
        let stepsRaw = stepSamples.reduce(0.0) { $0 + $1.value }
        let steps = UInt32(stepsRaw.rounded())

        // === Active Energy ===
        // Sum HKQuantityTypeIdentifierActiveEnergyBurned, multiply by 100
        let energySamples = daySamples.filter {
            $0.metricType == "HKQuantityTypeIdentifierActiveEnergyBurned"
        }
        let energyRaw = energySamples.reduce(0.0) { $0 + $1.value }  // kcal
        let activeEnergy = UInt32((energyRaw * 100).roundedHalfUp())

        // === Exercise Minutes ===
        // Sum durations of all HKWorkout samples starting within the day
        let exerciseSecondsTotal = dayWorkouts.reduce(0.0) { $0 + $1.duration }
        let exerciseMins = UInt16((exerciseSecondsTotal / 60).rounded())

        // === HRV ===
        // Average HKQuantityTypeIdentifierHeartRateVariabilitySDNN for the day.
        // Require minimum 2 samples — if fewer, mark absent.
        let hrvSamples = daySamples.filter {
            $0.metricType == "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
        }
        let hrvPresent = hrvSamples.count >= 2
        let hrv: UInt16
        if hrvPresent {
            let avgHRV = hrvSamples.reduce(0.0) { $0 + $1.value } / Double(hrvSamples.count)
            hrv = UInt16((avgHRV * 10).roundedHalfUp())
        } else {
            hrv = 0
        }

        // === Resting Heart Rate ===
        // HKQuantityTypeIdentifierRestingHeartRate — HealthKit provides one per day.
        // Use the first (and normally only) sample for the day.
        let restingHRPresent = !dayRHRSamples.isEmpty
        let restingHR: UInt16
        if restingHRPresent, let rhrSample = dayRHRSamples.first {
            restingHR = UInt16((rhrSample.value * 10).roundedHalfUp())
        } else {
            restingHR = 0
        }

        // === Sleep ===
        // Sum total sleep minutes for sessions with endDate in this day.
        // Apple native sleep analysis only — filter source bundle ID containing "com.apple.health".
        //
        // HealthKit sleep stage values (HKCategoryValueSleepAnalysis):
        //   0 = inBed                        (excluded — not actual sleep)
        //   1 = asleep (legacy unspecified)  (counted as total sleep, but no stage attribution)
        //   2 = awake                        (counted as awake within sleep window)
        //   3 = asleepCore (light)
        //   4 = asleepDeep
        //   5 = asleepREM
        // Anything in 1, 3, 4, 5 contributes to total sleepMins.
        let sleepSamples = daySamples.filter { s in
            s.metricType == "HKCategoryTypeIdentifierSleepAnalysis" &&
            s.sourceBundleID.contains("com.apple.health")
        }
        var totalSleepSecs: Double = 0
        var deepSleepSecs: Double = 0
        var remSleepSecs: Double = 0
        var lightSleepSecs: Double = 0
        var awakeWithinWindowSecs: Double = 0
        var anyStageReported = false
        for s in sleepSamples {
            let dur = s.endDate.timeIntervalSince(s.startDate)
            switch Int(s.value) {
            case 1: // asleep (unspecified)
                totalSleepSecs += dur
            case 2: // awake within sleep window
                awakeWithinWindowSecs += dur
                anyStageReported = true
            case 3: // asleepCore -> light
                totalSleepSecs += dur
                lightSleepSecs += dur
                anyStageReported = true
            case 4: // asleepDeep
                totalSleepSecs += dur
                deepSleepSecs += dur
                anyStageReported = true
            case 5: // asleepREM
                totalSleepSecs += dur
                remSleepSecs += dur
                anyStageReported = true
            default:
                // 0 = inBed and any unknown values are ignored
                break
            }
        }
        let sleepMins = UInt16((totalSleepSecs / 60).rounded())
        let deepSleepMins = UInt16((deepSleepSecs / 60).rounded())
        let remSleepMins = UInt16((remSleepSecs / 60).rounded())
        let lightSleepMins = UInt16((lightSleepSecs / 60).rounded())
        let awakeMins = UInt16((awakeWithinWindowSecs / 60).rounded())
        let sleepStagesPresent = anyStageReported

        // === Workout Count ===
        let workoutCount = UInt8(min(dayWorkouts.count, 255))

        // === Source Count ===
        let sourceCount = UInt8(min(allSourceIDs.count, 255))

        // === Blood Oxygen ===
        let bloodOxygenPresent = daySamples.contains {
            $0.metricType == "HKQuantityTypeIdentifierOxygenSaturation"
        }

        // === VO2 Max (v2) ===
        // HKQuantityTypeIdentifierVO2Max — typically reported in mL/(kg*min).
        // Apple Watch logs roughly one estimate per day; if multiple samples
        // exist on the same day we take the mean (matches the legitimacy
        // script's day-level granularity).
        let vo2maxSamples = daySamples.filter {
            $0.metricType == "HKQuantityTypeIdentifierVO2Max"
        }
        let vo2maxPresent = !vo2maxSamples.isEmpty
        let vo2max: UInt16
        if vo2maxPresent {
            let avg = vo2maxSamples.reduce(0.0) { $0 + $1.value } / Double(vo2maxSamples.count)
            vo2max = UInt16(min((avg * 10).roundedHalfUp(), Double(UInt16.max)))
        } else {
            vo2max = 0
        }

        // === Weight (v2) ===
        // HKQuantityTypeIdentifierBodyMass — kilograms. Stored as grams ÷ 10
        // (78.00 kg → 7800; range 0..655.35 kg). Take the latest sample of
        // the day if multiple, since weight drifts within the day and the
        // most recent reading is the most defensible "end of day" value.
        let weightSamples = daySamples
            .filter { $0.metricType == "HKQuantityTypeIdentifierBodyMass" }
            .sorted { $0.endDate > $1.endDate }
        let weightPresent = !weightSamples.isEmpty
        let weight: UInt16
        if weightPresent, let latest = weightSamples.first {
            // kg → grams (×1000) → grams/10 (÷10) so multiplier is ×100.
            weight = UInt16(min((latest.value * 100).roundedHalfUp(), Double(UInt16.max)))
        } else {
            weight = 0
        }

        // === Body Fat Percentage (v2) ===
        // HKQuantityTypeIdentifierBodyFatPercentage — fraction in [0, 1].
        // Stored as percent × 100 (0.185 → 1850).
        let bfpSamples = daySamples
            .filter { $0.metricType == "HKQuantityTypeIdentifierBodyFatPercentage" }
            .sorted { $0.endDate > $1.endDate }
        let bodyFatPctPresent = !bfpSamples.isEmpty
        let bodyFatPct: UInt16
        if bodyFatPctPresent, let latest = bfpSamples.first {
            // fraction × 10000 = percent × 100
            bodyFatPct = UInt16(min((latest.value * 10000).roundedHalfUp(), Double(UInt16.max)))
        } else {
            bodyFatPct = 0
        }

        // === Lean Body Mass (v2) ===
        // HKQuantityTypeIdentifierLeanBodyMass — kilograms. Same encoding as weight.
        let leanSamples = daySamples
            .filter { $0.metricType == "HKQuantityTypeIdentifierLeanBodyMass" }
            .sorted { $0.endDate > $1.endDate }
        let leanMassPresent = !leanSamples.isEmpty
        let leanMass: UInt16
        if leanMassPresent, let latest = leanSamples.first {
            leanMass = UInt16(min((latest.value * 100).roundedHalfUp(), Double(UInt16.max)))
        } else {
            leanMass = 0
        }

        // === Data Flags ===
        let dataFlags = computeDataFlags(
            steps: steps,
            activeEnergy: activeEnergy,
            exerciseMins: exerciseMins,
            hrvPresent: hrvPresent,
            restingHRPresent: restingHRPresent,
            sleepMins: sleepMins,
            workoutCount: workoutCount,
            bloodOxygenPresent: bloodOxygenPresent,
            sourceCount: sourceCount
        )

        // Skip day if truly no data of any kind (v1 or v2 metrics) is present
        let hasV2Signal = vo2maxPresent || weightPresent || bodyFatPctPresent ||
                          leanMassPresent || sleepStagesPresent
        guard dataFlags != 0 || workoutCount > 0 || sleepMins > 0 || hasV2Signal else {
            return nil
        }

        // === Source Hash ===
        let sourceHash = computeSourceHash(sourceBundleIDs: Array(allSourceIDs))

        // === Day ID ===
        let dayId = MerkleLeaf.dayId(for: dayStart, in: timezone)

        return NormalizedDailyLeaf(
            dayId: dayId,
            date: dayStart,
            timezone: timezone,
            walletAddress: walletAddress,
            steps: steps,
            activeEnergy: activeEnergy,
            exerciseMins: exerciseMins,
            hrv: hrv,
            restingHR: restingHR,
            sleepMins: sleepMins,
            workoutCount: workoutCount,
            sourceCount: sourceCount,
            dataFlags: dataFlags,
            sourceHash: sourceHash,
            hrvPresent: hrvPresent,
            restingHRPresent: restingHRPresent,
            bloodOxygenPresent: bloodOxygenPresent,
            vo2max: vo2max,
            weight: weight,
            bodyFatPct: bodyFatPct,
            leanMass: leanMass,
            deepSleepMins: deepSleepMins,
            remSleepMins: remSleepMins,
            lightSleepMins: lightSleepMins,
            awakeMins: awakeMins,
            vo2maxPresent: vo2maxPresent,
            weightPresent: weightPresent,
            bodyFatPctPresent: bodyFatPctPresent,
            leanMassPresent: leanMassPresent,
            sleepStagesPresent: sleepStagesPresent
        )
    }
}

// MARK: - HealthKit Integration Helpers

/// Adapters that convert HKSample types to our neutral HealthSample type.
/// These live outside MerkleNormalizationService to keep HealthKit imports isolated.
extension HealthSample {
    /// Create from an HKQuantitySample.
    init?(from hkSample: HKQuantitySample, preferredUnit: HKUnit) {
        guard let typeID = hkSample.quantityType.identifier as String? else { return nil }
        self.metricType = typeID
        self.value = hkSample.quantity.doubleValue(for: preferredUnit)
        self.unit = preferredUnit.unitString
        self.startDate = hkSample.startDate
        self.endDate = hkSample.endDate
        self.sourceBundleID = hkSample.sourceRevision.source.bundleIdentifier
        self.device = hkSample.device?.model
    }

    /// Create from an HKCategorySample (e.g. sleep analysis).
    init(from hkSample: HKCategorySample) {
        self.metricType = hkSample.categoryType.identifier
        self.value = Double(hkSample.value)
        self.unit = ""
        self.startDate = hkSample.startDate
        self.endDate = hkSample.endDate
        self.sourceBundleID = hkSample.sourceRevision.source.bundleIdentifier
        self.device = hkSample.device?.model
    }
}

extension WorkoutSample {
    /// Create from an HKWorkout.
    init(from workout: HKWorkout) {
        self.workoutType = workout.workoutActivityType
        self.startDate = workout.startDate
        self.endDate = workout.endDate
        self.duration = workout.duration
        self.sourceBundleID = workout.sourceRevision.source.bundleIdentifier
    }
}

// MARK: - Dominant Timezone Derivation

extension MerkleNormalizationService {
    /// Determine the dominant timezone from a set of samples.
    /// Uses the timezone of the majority of sample source apps.
    /// Falls back to the device's current timezone.
    static func dominantTimezone(from samples: [HealthSample]) -> TimeZone {
        // In practice, HealthKit samples don't expose timezone directly.
        // We use the device timezone as the canonical attribution timezone.
        // This matches Apple Health's own display convention.
        return TimeZone.current
    }
}

// MARK: - Double Rounding Helpers

private extension Double {
    /// Round half-up (0.5 rounds up, not to even). Used for deterministic integer encoding.
    func roundedHalfUp() -> Double {
        Foundation.floor(self + 0.5)
    }
}
