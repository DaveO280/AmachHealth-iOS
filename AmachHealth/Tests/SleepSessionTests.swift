// SleepSessionTests.swift
// AmachHealthTests
//
// Sleep is counted per night (session), one source per night, and credited
// to the day the night ends; plus the time and workout lines Luma gets.

import XCTest
@testable import AmachHealth

final class SleepSessionTests: XCTestCase {

    private let cal = Calendar.current

    /// Local time on a fixed date (the day the night ends is 2026-10-19).
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func s(_ start: Date, _ end: Date, _ value: Int, _ source: String = "com.apple.health.watch") -> SleepSample {
        SleepSample(start: start, end: end, value: value, source: source)
    }

    /// Dave's night: asleep 22:50 → 06:25 with stages, 7 h 35 min in total.
    private var watchNight: [SleepSample] {
        [
            s(at(18, 22, 40), at(19, 6, 30), 0),          // in bed
            s(at(18, 22, 50), at(18, 23, 30), 3),         // core, ends before midnight
            s(at(18, 23, 30), at(18, 23, 55), 4),         // deep, ends before midnight
            s(at(18, 23, 55), at(19, 1, 30), 3),          // core, crosses midnight
            s(at(19, 1, 30), at(19, 1, 45), 2),           // awake
            s(at(19, 1, 45), at(19, 3, 0), 5),            // REM
            s(at(19, 3, 0), at(19, 6, 25), 3),            // core
        ]
    }

    func test_a_night_that_starts_before_midnight_counts_whole_on_the_day_it_ends() throws {
        let rows = HealthKitIngestionService.sleepRows(watchNight)
        XCTAssertEqual(rows.count, 1, "no fragment row for the previous day")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.day, at(19, 6).vaultDay)
        XCTAssertEqual(row.total ?? 0, 455 - 15, accuracy: 0.001, "7 h 35 min asleep span minus the 15 min awake")
        XCTAssertEqual(row.sleepDeepMin ?? 0, 25, accuracy: 0.001)
        XCTAssertEqual(row.sleepRemMin ?? 0, 75, accuracy: 0.001)
        XCTAssertEqual(row.sleepAwakeMin ?? 0, 15, accuracy: 0.001)
    }

    func test_the_old_midnight_split_would_have_lost_the_pre_midnight_stages() {
        let midnight = cal.startOfDay(for: at(19, 6))
        let oldRule = watchNight.filter { $0.end >= midnight && $0.isAsleep }.reduce(0) { $0 + $1.minutes }
        let newRule = HealthKitIngestionService.sleepRows(watchNight).first?.total ?? 0
        XCTAssertEqual(newRule - oldRule, 65, accuracy: 0.001, "40 min core + 25 min deep before midnight")
    }

    func test_overlapping_sources_are_not_summed_and_stages_win() throws {
        // iPhone "asleep" estimate for the same night, longer but without stages.
        let phone = [s(at(18, 22, 30), at(19, 7, 0), 1, "com.apple.health.iphone")]
        let sessions = SleepSessionBuilder.sessions(watchNight + phone)
        XCTAssertEqual(Set(sessions.map(\.source)), ["com.apple.health.watch"])
        XCTAssertEqual(sessions.first?.ignoredSources, ["com.apple.health.iphone"])
        let row = try XCTUnwrap(HealthKitIngestionService.sleepRows(watchNight + phone).first)
        XCTAssertEqual(row.total ?? 0, 440, accuracy: 0.001)
    }

    func test_without_stages_the_source_with_more_sleep_wins() {
        let a = [s(at(18, 23, 0), at(19, 6, 0), 1, "app.a")]
        let b = [s(at(18, 23, 30), at(19, 7, 0), 1, "app.b")]
        let sessions = SleepSessionBuilder.sessions(a + b)
        XCTAssertEqual(sessions.map(\.source), ["app.b"])
    }

    func test_long_gaps_split_sessions_and_naps_do_not_replace_the_night() {
        let nap = [s(at(19, 14, 0), at(19, 14, 40), 3)]
        let sessions = SleepSessionBuilder.sessions(watchNight + nap)
        XCTAssertEqual(sessions.count, 2)
        let main = SleepSessionBuilder.mainSession(endingOn: at(19, 6).vaultDay, in: sessions)
        XCTAssertEqual(main?.asleepMinutes ?? 0, 440, accuracy: 0.001)
        // A short awake break keeps one session.
        let broken = [s(at(18, 23, 0), at(19, 2, 0), 3), s(at(19, 2, 40), at(19, 6, 0), 3)]
        XCTAssertEqual(SleepSessionBuilder.sessions(broken).count, 1)
    }

    func test_two_nights_land_on_their_own_days() {
        let nextNight = [s(at(19, 23, 10), at(20, 6, 40), 3)]
        let rows = HealthKitIngestionService.sleepRows(watchNight + nextNight).sorted { $0.day < $1.day }
        XCTAssertEqual(rows.map(\.day), [at(19, 6).vaultDay, at(20, 6).vaultDay])
        XCTAssertEqual(rows.last?.total ?? 0, 450, accuracy: 0.001)
    }

    func test_reingest_removes_healthkit_sleep_rows_but_keeps_imports() throws {
        let vault = try VaultDatabase.inMemory()
        try vault.upsertDailyMetrics([
            DailyMetricRow(day: "2026-10-18", metric: AmachMetric.sleepId, total: 65, count: 2, source: .healthKit),
            DailyMetricRow(day: "2026-10-17", metric: AmachMetric.sleepId, total: 400, count: 1, source: .importIOS),
        ], policy: .overwrite)
        try vault.deleteHealthKitSleepRows(days: ["2026-10-18", "2026-10-17"])
        XCTAssertNil(try vault.dailyMetric(metric: AmachMetric.sleepId, day: "2026-10-18"))
        XCTAssertNotNil(try vault.dailyMetric(metric: AmachMetric.sleepId, day: "2026-10-17"))
    }

    // MARK: - What Luma is told

    @MainActor func test_clock_line_gives_the_real_local_time_and_zone() {
        let zone = TimeZone(identifier: "America/New_York")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 13, minute: 34))!
        XCTAssertEqual(HealthContextBuilder.clockLine(now: now, timeZone: zone),
                       "User's local time now: Monday 19 October 2026, 09:34 (America/New_York, UTC-04:00).")
    }

    @MainActor func test_workout_lines_carry_times_day_and_source() throws {
        let now = at(19, 9, 34)
        let items = [
            WorkoutSummaryItem(date: at(18, 18, 5), activityType: "Walking", durationMinutes: 41.2,
                               endDate: at(18, 18, 46), sourceName: "Dave's Apple Watch"),
            WorkoutSummaryItem(date: at(19, 7, 0), activityType: "Running", durationMinutes: 30,
                               endDate: at(19, 7, 30), sourceName: nil),
        ]
        let text = try XCTUnwrap(HealthContextBuilder.formatWorkouts(items, now: now))
        XCTAssertTrue(text.contains("Sun 18 Oct (yesterday) 18:05–18:46: Walking, 41 min [Dave's Apple Watch]"), text)
        XCTAssertTrue(text.contains("Mon 19 Oct (today) 07:00–07:30: Running, 30 min"), text)
        XCTAssertTrue(text.contains("do not infer others"))
        XCTAssertNil(HealthContextBuilder.formatWorkouts([], now: now))
    }
}
