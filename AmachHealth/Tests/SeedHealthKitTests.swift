// SeedHealthKitTests.swift
// AmachHealthTests
//
// Run this test ONCE manually against a Simulator to populate 60 days of mock
// health data so Luma can be tested with a full context stack.
//
// ── How to run ──────────────────────────────────────────────────────────────
//
//   xcodebuild test \
//     -scheme AmachHealth \
//     -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
//     -only-testing 'AmachHealthTests/SeedHealthKitTests/testSeedHealthKitData' \
//     -testTimeoutsEnabled NO \
//     | xcpretty
//
// Or from Xcode: open the Test navigator, expand AmachHealthTests →
//   SeedHealthKitTests → testSeedHealthKitData, and press the run button.
//
// ── What happens ─────────────────────────────────────────────────────────────
//
//   • HealthKit prompts for write authorization — approve all categories.
//   • ~3,000 samples are written covering the last 60 days.
//   • Anomaly windows are embedded so AnomalyDetector and Luma have interesting
//     signal to surface:
//       – Days 15–17 : HRV 22 ms / RHR 82 bpm  (overtraining / illness)
//       – Day  30    : Steps 22,000             (unusual activity spike)
//       – Days 45–46 : Sleep 4.5 hrs            (poor sleep cluster)
//   • After seeding, launch the app, open Luma chat, and ask:
//     "How has my recovery been trending this month?"
//
// ── Notes ────────────────────────────────────────────────────────────────────
//
//   • Safe to re-run: HealthKit deduplicates by (type, start, end) so exact
//     duplicate samples from a second run are silently dropped.
//   • Does NOT affect any production data — Simulator HealthKit is isolated.
//   • CI: the test is automatically skipped when HealthKit is unavailable
//     (e.g. macOS CI runners), so it won't break your pipeline.

import XCTest
import HealthKit

final class SeedHealthKitTests: XCTestCase {

    @MainActor
    func testSeedHealthKitData() async throws {
        // Skip gracefully on macOS CI runners where HealthKit is not available.
        // When launched via seed-simulator.sh, SIMULATOR_UDID is always set
        // (xcodebuild injects it), so HealthKit will be available.
        guard HKHealthStore.isHealthDataAvailable() else {
            let onSimulator = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil
            if onSimulator {
                XCTFail("SIMULATOR_UDID is set but HealthKit reports unavailable — check entitlements.")
            } else {
                throw XCTSkip("HealthKit unavailable — not running on Simulator or device.")
            }
            return
        }

        let seeder = MockDataSeeder()
        try await seeder.seed(days: 60)
    }
}
