// VaultIngestionTests.swift
// AmachHealthTests
//
// HealthKit aggregation rules (pure functions), the dashboard reader over
// daily_metrics, and services persisting through an injected vault.

import XCTest
@testable import AmachHealth

final class VaultIngestionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func date(_ day: String, hour: Int = 12) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: VaultDay.date(day)!)!
    }

    // MARK: - Aggregation

    func test_sum_metric_prefers_deduplicated_total() throws {
        let steps = try XCTUnwrap(AmachMetric.byId["steps"])
        let rows = HealthKitIngestionService.quantityRows(
            metric: steps,
            values: [("2025-10-01", 4000), ("2025-10-01", 4000), ("2025-10-02", 10)],
            dedupedTotals: ["2025-10-01": 4500]
        )
        let byDay = Dictionary(uniqueKeysWithValues: rows.map { ($0.day, $0) })
        XCTAssertEqual(byDay["2025-10-01"]?.total, 4500, "Watch + iPhone overlap removed by HKStatistics")
        XCTAssertEqual(byDay["2025-10-01"]?.count, 2)
        XCTAssertEqual(byDay["2025-10-02"]?.total, 10, "falls back to the raw sum")
        XCTAssertNil(byDay["2025-10-01"]?.avg)
    }

    func test_range_metric_has_avg_min_max() throws {
        let hr = try XCTUnwrap(AmachMetric.byId["heart_rate"])
        let row = try XCTUnwrap(HealthKitIngestionService.quantityRows(
            metric: hr, values: [("2025-10-01", 50), ("2025-10-01", 70), ("2025-10-01", 90)], dedupedTotals: [:]
        ).first)
        XCTAssertEqual(row.avg, 70)
        XCTAssertEqual(row.min, 50)
        XCTAssertEqual(row.max, 90)
        XCTAssertEqual(row.count, 3)
        XCTAssertEqual(row.source, "healthkit")
    }

    func test_sleep_stage_rules_match_HealthKitService() throws {
        let end = date("2025-10-02", hour: 7)
        func s(_ minutes: Double, _ value: Int) -> (end: Date, start: Date, value: Int) {
            (end, end.addingTimeInterval(-minutes * 60), value)
        }
        let row = try XCTUnwrap(HealthKitIngestionService.sleepRows([
            s(480, 0),  // in bed
            s(30, 2),   // awake
            s(200, 3),  // core
            s(20, 1),   // unspecified asleep → core
            s(90, 4),   // deep
            s(100, 5),  // rem
        ]).first)
        XCTAssertEqual(row.day, "2025-10-02", "sleep belongs to the day it ends")
        XCTAssertEqual(row.total, 410)
        XCTAssertEqual(row.sleepCoreMin, 220)
        XCTAssertEqual(row.sleepDeepMin, 90)
        XCTAssertEqual(row.sleepRemMin, 100)
        XCTAssertEqual(row.sleepAwakeMin, 30)
        XCTAssertEqual(row.sleepInBedMin, 480)
        XCTAssertEqual(row.sleepEfficiency ?? 0, 410.0 / 480.0, accuracy: 1e-9)
    }

    func test_every_ingested_stream_uses_a_known_metric_and_unit() {
        for stream in HealthKitIngestionService.streams {
            XCTAssertNotNil(AmachMetric.unit(for: stream.id), stream.id)
            XCTAssertNotNil(stream.sampleType, stream.id)
        }
        XCTAssertTrue(HealthKitIngestionService.streams.contains(.sleep))
    }

    func test_legacy_keys_resolve_from_ios_web_and_healthkit_forms() {
        XCTAssertEqual(AmachMetric.resolve(legacyKey: "StepCount")?.id, "steps")
        XCTAssertEqual(AmachMetric.resolve(legacyKey: "stepCount")?.id, "steps")
        XCTAssertEqual(AmachMetric.resolve(legacyKey: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN")?.id, "hrv_sdnn")
        XCTAssertNil(AmachMetric.resolve(legacyKey: "notAMetric"))
    }

    // MARK: - Dashboard reader

    func test_dashboard_reader_builds_today_and_trends() throws {
        let vault = try VaultDatabase.inMemory()
        let today = now.vaultDay
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!.vaultDay
        let old = Calendar.current.date(byAdding: .day, value: -60, to: now)!.vaultDay
        var sleep = DailyMetricRow(day: today, metric: "sleep", total: 450, count: 6, source: .healthKit)
        sleep.sleepDeepMin = 90
        sleep.sleepCoreMin = 260
        sleep.sleepRemMin = 100
        sleep.sleepEfficiency = 0.9
        try vault.upsertDailyMetrics([
            DailyMetricRow(day: today, metric: "steps", total: 8000, count: 10, source: .healthKit),
            DailyMetricRow(day: yesterday, metric: "steps", total: 12000, count: 10, source: .healthKit),
            DailyMetricRow(day: old, metric: "steps", total: 3000, count: 10, source: .importIOS),
            DailyMetricRow(day: today, metric: "heart_rate", avg: 64, min: 50, max: 120, count: 100, source: .healthKit),
            DailyMetricRow(day: today, metric: "hrv_sdnn", avg: 55, count: 3, source: .healthKit),
            sleep,
        ], policy: .overwrite)

        let reader = VaultDashboardReader(vault: vault, now: now)
        let todayData = reader.today()
        XCTAssertEqual(todayData.steps, 8000)
        XCTAssertEqual(todayData.heartRateMax, 120)
        XCTAssertEqual(todayData.hrv, 55)
        XCTAssertEqual(todayData.sleepHours, 7.5)
        XCTAssertEqual(todayData.sleepStages.deepMinutes, 90)
        XCTAssertEqual(todayData.sleepEfficiency, 0.9)

        XCTAssertEqual(reader.trend("steps", days: 7).map(\.value), [12000, 8000])
        XCTAssertEqual(reader.trend("steps", days: 90).count, 3, "imported history shows in the 3-month trend")
        XCTAssertEqual(reader.sleepTrend(days: 7).first?.value, 7.5)
        XCTAssertEqual(reader.sleepStagesTrend(days: 7).first?.deepHours, 1.5)
    }

    // MARK: - Services on the vault

    @MainActor
    func test_chat_service_persists_through_the_vault() async throws {
        let vault = try VaultDatabase.inMemory()
        let first = ChatService(injectedAPI: MockAmachAPIClient(), injectedWallet: MockWalletService(), injectedVault: vault)
        first.currentSession.messages.append(ChatMessage(role: .user, content: "Remember me"))
        first.startNewSession()
        first.currentSession.messages.append(ChatMessage(role: .user, content: "Second session"))
        first.loadSession(first.currentSession)
        first.startNewSession()

        let reloaded = ChatService(injectedAPI: MockAmachAPIClient(), injectedWallet: MockWalletService(), injectedVault: vault)
        XCTAssertEqual(reloaded.recentSessions.count, 2)
        XCTAssertEqual(reloaded.recentSessions.flatMap(\.messages).map(\.content).sorted(), ["Remember me", "Second session"])
        XCTAssertTrue(reloaded.currentSession.messages.isEmpty)
    }

    func test_timeline_rows_roundtrip() throws {
        let vault = try VaultDatabase.inMemory()
        let event = TimelineEvent(
            id: "t1", eventType: .injuryOccurred, timestamp: Date(timeIntervalSince1970: 1_750_000_000),
            data: ["injury": "Sprained ankle"],
            metadata: TimelineEventMetadata(platform: "ios", version: "1", source: .userEntered),
            attestationTxHash: "0xabc"
        )
        try vault.saveTimelineEvents([event], origin: "device")
        XCTAssertEqual(try vault.timelineEvents(), [event])
        try vault.deleteTimelineEvent(id: "t1")
        XCTAssertTrue(try vault.timelineEvents().isEmpty)
    }
}
