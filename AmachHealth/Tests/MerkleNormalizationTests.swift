// MerkleNormalizationTests.swift
// AmachHealth
//
// Phase 1 gate tests for MerkleLeaf serialization and MerkleNormalizationService.
// All 6 gate tests must pass before advancing to Phase 2.
//
// Run with: swift test --filter MerkleNormalizationTests

import XCTest
@testable import AmachHealth
import Foundation

final class MerkleNormalizationTests: XCTestCase {

    // MARK: - Test Infrastructure

    /// Fake wallet address for tests (32 bytes, EVM-style)
    let testWallet = Data(hex: "0x000000000000000000000000abcdef1234567890abcdef1234567890abcdef12")!

    /// 2024-01-01 in EST (UTC-5) — the epoch start day
    let timezone = TimeZone(identifier: "America/New_York")!

    lazy var service = MerkleNormalizationService(walletAddress: testWallet)

    // MARK: - MerkleLeaf Serialization Tests

    func testLeafSerializationLength() {
        // A serialized leaf must be exactly 90 bytes
        let leaf = makeSampleLeaf()
        let bytes = leaf.serialize()
        XCTAssertEqual(bytes.count, 90, "Serialized leaf must be exactly 90 bytes")
    }

    func testLeafSerializationRoundtrip() {
        // Deserialization must recover identical values
        let leaf = makeSampleLeaf()
        let bytes = leaf.serialize()
        guard let recovered = MerkleLeaf.deserialize(from: bytes) else {
            XCTFail("Deserialization returned nil")
            return
        }
        XCTAssertEqual(leaf, recovered, "Round-trip must produce identical leaf")
    }

    func testLeafFieldLayout() {
        // Verify specific byte positions match the protocol spec
        let leaf = MerkleLeaf(
            dayId: 100,         // 0x00000064
            wallet: Data(repeating: 0xAB, count: 32),
            timezoneOffset: -300, // EST: 0xFED4
            steps: 8000,        // 0x00001F40
            activeEnergy: 35050, // 0x00008902
            exerciseMins: 45,
            hrv: 423,
            restingHR: 580,
            sleepMins: 420,
            workoutCount: 1,
            sourceCount: 2,
            dataFlags: 0b0000_0001_0111_1111, // bits 0-7 + 8
            sourceHash: Data(repeating: 0xCC, count: 32)
        )
        let bytes = leaf.serialize()

        // bytes 0-3: day_id = 100 = 0x00000064
        XCTAssertEqual(bytes[0], 0x00)
        XCTAssertEqual(bytes[1], 0x00)
        XCTAssertEqual(bytes[2], 0x00)
        XCTAssertEqual(bytes[3], 0x64)

        // bytes 4-35: wallet (0xAB repeated)
        XCTAssertTrue(bytes[4..<36].allSatisfy { $0 == 0xAB }, "Wallet bytes mismatch")

        // bytes 36-37: timezone_offset = -300 big-endian = 0xFED4
        XCTAssertEqual(bytes[36], 0xFE)
        XCTAssertEqual(bytes[37], 0xD4)

        // bytes 38-41: steps = 8000 = 0x00001F40
        XCTAssertEqual(bytes[38], 0x00)
        XCTAssertEqual(bytes[39], 0x00)
        XCTAssertEqual(bytes[40], 0x1F)
        XCTAssertEqual(bytes[41], 0x40)

        // byte 54: workout_count = 1
        XCTAssertEqual(bytes[54], 0x01)

        // byte 55: source_count = 2
        XCTAssertEqual(bytes[55], 0x02)

        // bytes 58-89: source_hash (0xCC repeated)
        XCTAssertTrue(bytes[58..<90].allSatisfy { $0 == 0xCC }, "Source hash bytes mismatch")
    }

    // MARK: - Gate Test 1: Single Day Spot Check

    func testGate1_SingleDaySpotCheck() throws {
        // Build a controlled set of samples for 2024-01-15 (dayId = 14)
        let jan15 = makeDate(year: 2024, month: 1, day: 15)

        let samples: [HealthSample] = [
            // Steps: 3 samples summing to 9,234
            makeQuantitySample(type: "HKQuantityTypeIdentifierStepCount",
                               value: 3000, start: jan15, end: jan15.addingTimeInterval(3600),
                               source: "com.apple.health"),
            makeQuantitySample(type: "HKQuantityTypeIdentifierStepCount",
                               value: 4000, start: jan15, end: jan15.addingTimeInterval(7200),
                               source: "com.apple.health"),
            makeQuantitySample(type: "HKQuantityTypeIdentifierStepCount",
                               value: 2234, start: jan15, end: jan15.addingTimeInterval(10800),
                               source: "com.apple.health.watchOS"),

            // Active energy: 320.75 kcal → stored as 32075
            makeQuantitySample(type: "HKQuantityTypeIdentifierActiveEnergyBurned",
                               value: 200.50, start: jan15, end: jan15.addingTimeInterval(3600),
                               source: "com.apple.health"),
            makeQuantitySample(type: "HKQuantityTypeIdentifierActiveEnergyBurned",
                               value: 120.25, start: jan15, end: jan15.addingTimeInterval(7200),
                               source: "com.apple.health.watchOS"),

            // HRV: 3 samples (above minimum) averaging 42.3 ms → stored as 423
            makeQuantitySample(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                               value: 40.0, start: jan15, end: jan15.addingTimeInterval(3600),
                               source: "com.apple.health"),
            makeQuantitySample(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                               value: 43.0, start: jan15, end: jan15.addingTimeInterval(7200),
                               source: "com.apple.health"),
            makeQuantitySample(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                               value: 43.9, start: jan15, end: jan15.addingTimeInterval(10800),
                               source: "com.apple.health"),
        ]

        let restingHR: [HealthSample] = [
            // Resting HR: 58.0 bpm → stored as 580
            makeQuantitySample(type: "HKQuantityTypeIdentifierRestingHeartRate",
                               value: 58.0, start: jan15, end: jan15.addingTimeInterval(3600),
                               source: "com.apple.health"),
        ]

        let leaves = service.normalize(
            samples: samples,
            workouts: [],
            restingHRSamples: restingHR,
            start: jan15,
            end: jan15.addingTimeInterval(86399),
            timezone: timezone
        )

        XCTAssertEqual(leaves.count, 1, "Expected exactly one leaf for Jan 15")

        let leaf = leaves[0]

        // dayId for 2024-01-15 (14 days after epoch 2024-01-01)
        XCTAssertEqual(leaf.dayId, 14, "dayId for 2024-01-15 should be 14")

        // Steps: 3000 + 4000 + 2234 = 9234
        XCTAssertEqual(leaf.steps, 9234, "Steps should sum to 9234")

        // Active energy: 200.50 + 120.25 = 320.75 kcal → 320.75 * 100 = 32075
        XCTAssertEqual(leaf.activeEnergy, 32075, "Active energy should be 32075")

        // HRV: avg(40.0, 43.0, 43.9) = 126.9 / 3 = 42.3 ms → 42.3 * 10 = 423 (rounded)
        XCTAssertEqual(leaf.hrv, 423, "HRV should be 423 (42.3 ms * 10)")
        XCTAssertTrue(leaf.hrvPresent, "HRV should be marked as present")

        // Resting HR: 58.0 bpm → 58.0 * 10 = 580
        XCTAssertEqual(leaf.restingHR, 580, "Resting HR should be 580 (58.0 bpm * 10)")
        XCTAssertTrue(leaf.restingHRPresent, "Resting HR should be marked as present")

        // 2 distinct sources → multi-source day flag set, sourceCount = 2
        XCTAssertEqual(leaf.sourceCount, 2, "Should have 2 distinct source bundle IDs")
        XCTAssertTrue(leaf.dataFlags & MerkleLeafFlag.multiSourceDay.rawValue != 0,
                      "Multi-source flag should be set")
    }

    // MARK: - Gate Test 2: Missing Day Handling

    func testGate2_MissingDayHandling() {
        // A day with zero samples of any kind should produce no leaf
        let jan20 = makeDate(year: 2024, month: 1, day: 20)
        let jan21 = makeDate(year: 2024, month: 1, day: 21)
        let jan22 = makeDate(year: 2024, month: 1, day: 22)

        // Only provide samples for Jan 20 and 22; Jan 21 has nothing
        let samples: [HealthSample] = [
            makeQuantitySample(type: "HKQuantityTypeIdentifierStepCount",
                               value: 5000, start: jan20, end: jan20.addingTimeInterval(3600),
                               source: "com.apple.health"),
            makeQuantitySample(type: "HKQuantityTypeIdentifierStepCount",
                               value: 7000, start: jan22, end: jan22.addingTimeInterval(3600),
                               source: "com.apple.health"),
        ]

        let leaves = service.normalize(
            samples: samples,
            workouts: [],
            restingHRSamples: [],
            start: jan20,
            end: jan22.addingTimeInterval(86399),
            timezone: timezone
        )

        // Should have leaves for Jan 20 and Jan 22, but NOT Jan 21
        XCTAssertEqual(leaves.count, 2, "Expected leaves for 2 days, not 3 (gap day omitted)")

        let dayIds = leaves.map { $0.dayId }
        XCTAssertTrue(dayIds.contains(MerkleLeaf.dayId(for: jan20, in: timezone)), "Jan 20 leaf missing")
        XCTAssertTrue(dayIds.contains(MerkleLeaf.dayId(for: jan22, in: timezone)), "Jan 22 leaf missing")
        XCTAssertFalse(dayIds.contains(MerkleLeaf.dayId(for: jan21, in: timezone)), "Jan 21 should be absent (no data)")
    }

    // MARK: - Gate Test 3: Sleep Crossing Midnight

    func testGate3_SleepCrossingMidnight() {
        // Sleep session starts Jan 15 at 11 PM and ends Jan 16 at 7 AM (8 hours = 480 min)
        let jan15_11pm = makeDate(year: 2024, month: 1, day: 15, hour: 23, minute: 0)
        let jan16_7am  = makeDate(year: 2024, month: 1, day: 16, hour: 7,  minute: 0)

        let samples: [HealthSample] = [
            // Sleep session: endDate is Jan 16 → attributed to Jan 16
            makeSleepSample(start: jan15_11pm, end: jan16_7am, source: "com.apple.health"),
            // Add steps on Jan 16 so we have a non-trivial leaf
            makeQuantitySample(type: "HKQuantityTypeIdentifierStepCount",
                               value: 3000, start: jan16_7am, end: jan16_7am.addingTimeInterval(3600),
                               source: "com.apple.health"),
        ]

        let jan15 = makeDate(year: 2024, month: 1, day: 15)
        let jan16 = makeDate(year: 2024, month: 1, day: 16)

        let leaves = service.normalize(
            samples: samples,
            workouts: [],
            restingHRSamples: [],
            start: jan15,
            end: jan16.addingTimeInterval(86399),
            timezone: timezone
        )

        // Sleep is attributed to Jan 16 (the day the session ended)
        let jan16DayId = MerkleLeaf.dayId(for: jan16, in: timezone)
        let jan15DayId = MerkleLeaf.dayId(for: jan15, in: timezone)

        guard let jan16Leaf = leaves.first(where: { $0.dayId == jan16DayId }) else {
            XCTFail("Jan 16 leaf not found")
            return
        }

        // 8 hours = 480 minutes
        XCTAssertEqual(jan16Leaf.sleepMins, 480, "Sleep should be 480 min (8 hours), attributed to Jan 16")
        XCTAssertTrue(jan16Leaf.dataFlags & MerkleLeafFlag.sleepPresent.rawValue != 0,
                      "Sleep flag should be set for Jan 16")

        // Jan 15 should have no sleep
        if let jan15Leaf = leaves.first(where: { $0.dayId == jan15DayId }) {
            XCTAssertEqual(jan15Leaf.sleepMins, 0, "Jan 15 should have 0 sleep minutes")
        }
        // (Jan 15 may be absent entirely if no other samples — that's also correct)
    }

    // MARK: - Gate Test 4: HRV Minimum Sample Threshold

    func testGate4_HRVMinimumSampleThreshold() {
        // A day with only 1 HRV sample → HRV should be marked absent, value = 0
        let jan15 = makeDate(year: 2024, month: 1, day: 15)

        let samples: [HealthSample] = [
            // Only 1 HRV sample — below the 2-sample minimum
            makeQuantitySample(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                               value: 45.0, start: jan15, end: jan15.addingTimeInterval(3600),
                               source: "com.apple.health"),
            // Add steps so the day isn't empty
            makeQuantitySample(type: "HKQuantityTypeIdentifierStepCount",
                               value: 5000, start: jan15, end: jan15.addingTimeInterval(3600),
                               source: "com.apple.health"),
        ]

        let leaves = service.normalize(
            samples: samples,
            workouts: [],
            restingHRSamples: [],
            start: jan15,
            end: jan15.addingTimeInterval(86399),
            timezone: timezone
        )

        XCTAssertEqual(leaves.count, 1)
        let leaf = leaves[0]

        XCTAssertFalse(leaf.hrvPresent, "HRV with only 1 sample should be marked absent")
        XCTAssertEqual(leaf.hrv, 0, "HRV value should be 0 when absent")
        XCTAssertTrue(leaf.dataFlags & MerkleLeafFlag.hrvPresent.rawValue == 0,
                      "HRV flag should NOT be set when only 1 sample present")
    }

    // MARK: - Gate Test 5: Determinism

    func testGate5_Determinism() {
        // Run normalization twice on identical inputs — output must be byte-for-byte identical
        let jan15 = makeDate(year: 2024, month: 1, day: 15)

        let samples: [HealthSample] = [
            makeQuantitySample(type: "HKQuantityTypeIdentifierStepCount",
                               value: 8743, start: jan15, end: jan15.addingTimeInterval(3600),
                               source: "com.apple.health"),
            makeQuantitySample(type: "HKQuantityTypeIdentifierActiveEnergyBurned",
                               value: 312.5, start: jan15, end: jan15.addingTimeInterval(7200),
                               source: "com.apple.health.watchOS"),
            makeQuantitySample(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                               value: 38.2, start: jan15, end: jan15.addingTimeInterval(3600),
                               source: "com.apple.health"),
            makeQuantitySample(type: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
                               value: 40.1, start: jan15, end: jan15.addingTimeInterval(7200),
                               source: "com.apple.health"),
        ]

        let leaves1 = service.normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: jan15, end: jan15.addingTimeInterval(86399), timezone: timezone
        )

        let leaves2 = service.normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: jan15, end: jan15.addingTimeInterval(86399), timezone: timezone
        )

        XCTAssertEqual(leaves1.count, leaves2.count, "Leaf count must be identical across runs")

        for (l1, l2) in zip(leaves1, leaves2) {
            let bytes1 = l1.toMerkleLeaf().serialize()
            let bytes2 = l2.toMerkleLeaf().serialize()
            XCTAssertEqual(bytes1, bytes2, "Leaf bytes must be identical across runs (determinism)")
        }
    }

    // MARK: - Gate Test 6: 90-Day Output Range

    func testGate6_NinetyDayOutputRange() {
        // Generate 90 days of sample data with realistic gaps (simulating ~10 days off)
        var allSamples: [HealthSample] = []
        let start = makeDate(year: 2024, month: 1, day: 1)

        for dayOffset in 0..<90 {
            guard let dayStart = Calendar.current.date(byAdding: .day, value: dayOffset, to: start) else {
                continue
            }

            // Simulate 10% of days having no data (e.g. watch not worn)
            if dayOffset % 11 == 0 { continue }

            allSamples.append(makeQuantitySample(
                type: "HKQuantityTypeIdentifierStepCount",
                value: Double(5000 + (dayOffset * 137) % 5000),
                start: dayStart,
                end: dayStart.addingTimeInterval(3600),
                source: "com.apple.health"
            ))
        }

        let end = makeDate(year: 2024, month: 3, day: 31)
        let leaves = service.normalize(
            samples: allSamples, workouts: [], restingHRSamples: [],
            start: start, end: end, timezone: timezone
        )

        // Expect between 60 and 90 leaves (realistic range for wearable user)
        XCTAssertGreaterThanOrEqual(leaves.count, 60, "Expected at least 60 leaves for 90 days")
        XCTAssertLessThanOrEqual(leaves.count, 90, "Expected at most 90 leaves for 90 days")

        // Verify leaves are sorted by dayId
        for i in 1..<leaves.count {
            XCTAssertGreaterThan(leaves[i].dayId, leaves[i-1].dayId,
                                 "Leaves must be sorted ascending by dayId")
        }

        // Verify no duplicate dayIds
        let dayIds = leaves.map { $0.dayId }
        XCTAssertEqual(Set(dayIds).count, leaves.count, "No duplicate dayIds allowed")

        print("✅ Gate 6: Generated \(leaves.count) leaves over 90-day window")
    }

    // MARK: - Day ID Tests

    func testDayIdEpoch() {
        let epoch = makeDate(year: 2024, month: 1, day: 1)
        let tz = TimeZone(identifier: "UTC")!
        XCTAssertEqual(MerkleLeaf.dayId(for: epoch, in: tz), 0, "Epoch day (2024-01-01) should be day 0")
    }

    func testDayIdJan15_2024() {
        let jan15 = makeDate(year: 2024, month: 1, day: 15)
        let tz = TimeZone(identifier: "UTC")!
        XCTAssertEqual(MerkleLeaf.dayId(for: jan15, in: tz), 14, "2024-01-15 should be day 14")
    }

    func testDayIdRoundtrip() {
        let tz = TimeZone(identifier: "America/New_York")!
        for dayId: UInt32 in [0, 1, 100, 365, 730] {
            let date = MerkleLeaf.date(for: dayId, in: tz)
            let recovered = MerkleLeaf.dayId(for: date, in: tz)
            XCTAssertEqual(recovered, dayId, "DayId round-trip failed for \(dayId)")
        }
    }

    // MARK: - Source Hash Tests

    func testSourceHashDeterminism() {
        let ids1 = ["com.apple.health", "com.apple.health.watchOS", "com.runkeeper.app"]
        let ids2 = ["com.runkeeper.app", "com.apple.health.watchOS", "com.apple.health"]  // different order

        let hash1 = computeSourceHash(sourceBundleIDs: ids1)
        let hash2 = computeSourceHash(sourceBundleIDs: ids2)

        XCTAssertEqual(hash1, hash2, "Source hash must be order-independent (sorted before hashing)")
        XCTAssertEqual(hash1.count, 32, "Source hash must be 32 bytes (SHA256)")
    }

    func testSourceHashSensitivity() {
        let hash1 = computeSourceHash(sourceBundleIDs: ["com.apple.health"])
        let hash2 = computeSourceHash(sourceBundleIDs: ["com.apple.health2"])
        XCTAssertNotEqual(hash1, hash2, "Source hash must change when inputs change")
    }

    // MARK: - DataFlags Tests

    func testDataFlagsAllPresent() {
        let flags = computeDataFlags(
            steps: 5000,
            activeEnergy: 30000,
            exerciseMins: 45,
            hrvPresent: true,
            restingHRPresent: true,
            sleepMins: 420,
            workoutCount: 1,
            bloodOxygenPresent: true,
            sourceCount: 3
        )

        XCTAssertTrue(flags & MerkleLeafFlag.stepsPresent.rawValue        != 0, "steps flag")
        XCTAssertTrue(flags & MerkleLeafFlag.activeEnergyPresent.rawValue != 0, "energy flag")
        XCTAssertTrue(flags & MerkleLeafFlag.exerciseMinsPresent.rawValue != 0, "exercise flag")
        XCTAssertTrue(flags & MerkleLeafFlag.hrvPresent.rawValue          != 0, "hrv flag")
        XCTAssertTrue(flags & MerkleLeafFlag.restingHRPresent.rawValue    != 0, "rhr flag")
        XCTAssertTrue(flags & MerkleLeafFlag.sleepPresent.rawValue        != 0, "sleep flag")
        XCTAssertTrue(flags & MerkleLeafFlag.workoutLogged.rawValue       != 0, "workout flag")
        XCTAssertTrue(flags & MerkleLeafFlag.bloodOxygenPresent.rawValue  != 0, "spo2 flag")
        XCTAssertTrue(flags & MerkleLeafFlag.multiSourceDay.rawValue      != 0, "multi-source flag")
    }

    // MARK: - Helpers

    private func makeSampleLeaf() -> MerkleLeaf {
        MerkleLeaf(
            dayId: 42,
            wallet: testWallet,
            timezoneOffset: -300,
            steps: 8500,
            activeEnergy: 35000,
            exerciseMins: 60,
            hrv: 412,
            restingHR: 560,
            sleepMins: 450,
            workoutCount: 2,
            sourceCount: 3,
            dataFlags: 0b0000_0001_0111_1111,
            sourceHash: computeSourceHash(sourceBundleIDs: ["com.apple.health", "com.apple.health.watchOS", "com.runkeeper.app"])
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func makeQuantitySample(
        type: String,
        value: Double,
        start: Date,
        end: Date,
        source: String
    ) -> HealthSample {
        HealthSample(
            metricType: type,
            value: value,
            unit: "",
            startDate: start,
            endDate: end,
            sourceBundleID: source,
            device: nil
        )
    }

    private func makeSleepSample(start: Date, end: Date, source: String) -> HealthSample {
        HealthSample(
            metricType: "HKCategoryTypeIdentifierSleepAnalysis",
            value: 1.0,  // HKCategoryValueSleepAnalysis.asleep
            unit: "",
            startDate: start,
            endDate: end,
            sourceBundleID: source,
            device: nil
        )
    }
}

// MARK: - Data hex convenience

private extension Data {
    init?(hex: String) {
        let stripped = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard stripped.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = stripped.startIndex
        while index < stripped.endIndex {
            let next = stripped.index(index, offsetBy: 2)
            guard let byte = UInt8(stripped[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
