// LumaContextInspector.swift
// AmachHealth
//
// "What Luma sees": keeps the exact context blocks sent with the last Luma
// message (on this phone only, in memory), and reconciles the numbers in
// them against fresh HealthKit queries so wrong figures are easy to spot.

import Foundation
import HealthKit

@MainActor
final class LumaContextInspector: ObservableObject {
    static let shared = LumaContextInspector()

    struct Snapshot {
        let sentAt: Date
        let intent: String
        let mode: String
        let blocks: [ContextBlock]
        /// The context exactly as encoded for /api/ai/chat.
        let json: String
    }

    @Published private(set) var lastSent: Snapshot?

    private init() {}

    func record(_ context: AIChatContext?, intent: ChatIntent, mode: ChatMode) {
        lastSent = Self.snapshot(context, intent: "\(intent)", mode: mode.rawValue)
    }

    /// The context Luma would get for a general deep question right now.
    func preview() -> Snapshot? {
        Self.snapshot(HealthContextBuilder.buildContext(for: .general, mode: .deep), intent: "general (preview)", mode: ChatMode.deep.rawValue)
    }

    static func snapshot(_ context: AIChatContext?, intent: String, mode: String) -> Snapshot? {
        guard let context else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = (try? encoder.encode(context)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return Snapshot(sentAt: Date(), intent: intent, mode: mode, blocks: context.contextBlocks ?? [], json: json)
    }
}

// MARK: - Reconciliation

/// Compares what Luma is given with what HealthKit reports right now.
struct LumaReconciliation {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let lumaValue: String
        let healthKitValue: String
        let matches: Bool?
        var note: String? = nil
    }

    struct SessionLine: Identifiable {
        let id = UUID()
        let source: String
        let start: Date
        let end: Date
        let asleepMinutes: Double
        let counted: Bool
    }

    var rows: [Row] = []
    var sessions: [SessionLine] = []
    var workouts: [WorkoutSummaryItem] = []
    var clock: String = ""

    @MainActor
    static func run(store: HKHealthStore = HKHealthStore(), now: Date = Date()) async -> LumaReconciliation {
        var result = LumaReconciliation()
        result.clock = HealthContextBuilder.clockLine(now: now)
        let dashboard = DashboardService.shared
        let today = dashboard.today
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)

        // Sleep: sessions ending today, as Apple's Time Asleep counts them.
        let samples = await HealthKitIngestionService.sleepSamples(store: store, range: startOfToday..<now)
        let sessions = SleepSessionBuilder.sessions(samples).filter { $0.day == now.vaultDay }
        let healthKitSleep = sessions.reduce(0) { $0 + $1.asleepMinutes } / 60
        // The old rule: every asleep sample that ended after midnight, all sources summed.
        let midnightSplit = samples.filter { $0.end >= startOfToday && $0.isAsleep }.reduce(0) { $0 + $1.minutes } / 60
        result.rows.append(Row(
            label: "Sleep last night",
            lumaValue: hoursText(today.sleepHours),
            healthKitValue: hoursText(healthKitSleep),
            matches: abs(today.sleepHours - healthKitSleep) < 0.1,
            note: abs(midnightSplit - healthKitSleep) > 0.05
                ? "Counting only stages after midnight gives \(hoursText(midnightSplit)) (the old rule)."
                : nil
        ))
        result.sessions = sessions.map {
            SessionLine(source: $0.source, start: $0.start, end: $0.end, asleepMinutes: $0.asleepMinutes, counted: true)
        }
        // Sources HealthKit has for the same night that weren't counted.
        let ignored = Set(sessions.flatMap(\.ignoredSources))
        for source in ignored {
            let own = SleepSessionBuilder.sessions(samples.filter { $0.source == source }).filter { $0.day == now.vaultDay }
            result.sessions += own.map {
                SessionLine(source: $0.source, start: $0.start, end: $0.end, asleepMinutes: $0.asleepMinutes, counted: false)
            }
        }

        // Today's running totals (HealthKit's deduplicated sums).
        let quantityChecks: [(String, HKQuantityTypeIdentifier, HKUnit, Double, String)] = [
            ("Steps today", .stepCount, .count(), today.steps, "%.0f"),
            ("Active energy today", .activeEnergyBurned, .kilocalorie(), today.activeCalories, "%.0f kcal"),
            ("Exercise today", .appleExerciseTime, .minute(), today.exerciseMinutes, "%.0f min"),
        ]
        for (label, id, unit, lumaValue, format) in quantityChecks {
            let fresh = await sum(store: store, id: id, unit: unit, start: startOfToday, end: now)
            let tolerance = max(1, (fresh ?? 0) * 0.02)
            result.rows.append(Row(
                label: label,
                lumaValue: String(format: format, lumaValue),
                healthKitValue: fresh.map { String(format: format, $0) } ?? "no data",
                matches: fresh.map { abs($0 - lumaValue) <= tolerance },
                note: (fresh ?? 0) - lumaValue > tolerance ? "Luma's copy is older than HealthKit (refreshes every 5 min)." : nil
            ))
        }

        // Workouts with times and sources.
        result.workouts = await dashboard.fetchRecentWorkoutSummaries(days: 2)
        let lumaWorkoutCount = dashboard.recentWorkoutSummaries.filter { now.timeIntervalSince($0.date) < 2 * 86_400 }.count
        result.rows.append(Row(
            label: "Workouts, last 48 h",
            lumaValue: "\(lumaWorkoutCount)",
            healthKitValue: "\(result.workouts.count)",
            matches: lumaWorkoutCount == result.workouts.count
        ))
        return result
    }

    static func hoursText(_ hours: Double) -> String {
        guard hours > 0 else { return "none" }
        let total = Int((hours * 60).rounded())
        return "\(total / 60) h \(total % 60) min"
    }

    private static func sum(store: HKHealthStore, id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
}
