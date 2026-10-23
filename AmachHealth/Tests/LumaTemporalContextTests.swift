// LumaTemporalContextTests.swift
// AmachHealthTests
//
// Luma must know how old each piece of data is, and reach older data:
//   • every report carries its date and age, worked out on the phone
//   • reports are ordered by their real date, whatever format it came in
//   • older reports, long-term wearable history and periods the user names
//     reach the context
//   • the classifier routes mixed questions to every topic they touch
//   • memory reaches the backend as a block, with dates
//   • memory builds without New Chat, retires facts that no longer hold,
//     keeps one summary per session and carries preferences

import XCTest
import GRDB
@testable import AmachHealth

@MainActor
final class LumaTemporalContextTests: XCTestCase {

    private var dir: URL!
    private let service = PDFUploadService.shared
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()
    /// Wednesday 21 October 2026, midday.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("luma-time-\(UUID().uuidString)")
        BackupService.autoRunEnabled = false
        StorjImportService.autoRunEnabled = false
        let key = WalletEncryptionKey(walletAddress: WalletDecryptorFixtures.walletAddress,
                                      encryptionKey: WalletDecryptorFixtures.encryptionKey, signature: "0x", timestamp: 0)
        LocalVault.shared.open(walletKey: key, directory: dir)
        LabContextService.shared.invalidate()
        service.reset()
    }

    override func tearDown() async throws {
        LocalVault.shared.close(forget: true)
        BackupService.autoRunEnabled = true
        StorjImportService.autoRunEnabled = true
        service.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func save(_ report: ParsedHealthReport, name: String) {
        var pdf = MockPDFReports.mockBloodworkPDF()
        pdf.append(Data(name.utf8))
        service.save(PDFReadResult(report: report, reader: .privateAI(model: "test"), filename: name,
                                   pdfData: pdf, seconds: 1))
        guard case .done = service.state else { return XCTFail("save failed: \(service.state)") }
        LabContextService.shared.invalidate()
    }

    private func gut(date: String?, score: Double) throws -> GutHealthReport {
        var json: [String: Any] = [
            "provider": "Tiny Health",
            "summary": ["microbiome_score": score],
            "other_metrics": [["name": "Cellulose", "value": score, "unit": "rpkm", "section": "Digestive capacity"]],
        ]
        if let date { json["collection_date"] = date }
        return try XCTUnwrap(GutHealthReport(json: json))
    }

    private func bloodwork(date: String, ldl: Double) -> BloodworkReportData {
        let metric = BloodworkMetric(name: "LDL Cholesterol", value: ldl, valueText: nil, unit: "mg/dL",
                                     referenceRange: "<100", panel: nil, collectedAt: nil, flag: nil,
                                     interpretationNotes: nil)
        return BloodworkReportData(type: "bloodwork", source: "Lab", reportDate: date, laboratory: "Quest", panels: [:],
                                   metrics: [metric], notes: nil, rawText: "bw \(date) \(ldl)", confidence: 1)
    }

    private func blocks(_ type: String) -> [String] {
        HealthContextBuilder.labBlocks(now: now).filter { $0.type == type }.map(\.content)
    }

    // MARK: - Dates and ages

    func test_report_dates_parse_in_the_formats_reports_use() {
        let may14 = day(2026, 5, 14)
        for raw in ["2026-05-14", "2026-05-14T00:00:00Z", "05/14/2026", "5/14/26", "May 14, 2026",
                    "May 14th, 2026", "14 May 2026", "May 14 2026"] {
            XCTAssertEqual(LumaDate.parse(raw, calendar: calendar), may14, raw)
        }
        XCTAssertEqual(LumaDate.parse("May 2026", calendar: calendar), day(2026, 5, 1))
        XCTAssertNil(LumaDate.parse("sometime in spring", calendar: calendar))
        XCTAssertNil(LumaDate.parse(nil, calendar: calendar))
    }

    func test_ages_are_worked_out_not_left_to_the_model() {
        func age(_ d: Date) -> String { LumaDate.age(of: d, now: now, calendar: calendar) }
        XCTAssertEqual(age(day(2026, 10, 21)), "today")
        XCTAssertEqual(age(day(2026, 10, 20)), "yesterday")
        XCTAssertEqual(age(day(2026, 10, 11)), "10 days ago")
        XCTAssertEqual(age(day(2026, 9, 9)), "6 weeks ago")
        XCTAssertEqual(age(day(2026, 5, 14)), "5 months ago", "the gut test from May is not 6-8 weeks old")
        XCTAssertEqual(age(day(2025, 11, 3)), "11 months ago")
        XCTAssertEqual(age(day(2024, 6, 1)), "2 years ago")
        XCTAssertEqual(LumaDate.stamp("May 14, 2026", now: now, calendar: calendar), "2026-05-14, 5 months ago")
    }

    // MARK: - Reports carry their age

    func test_gut_report_from_may_is_labeled_five_months_old() throws {
        save(.gutHealth(try gut(date: "2026-05-14", score: 61)), name: "gut.pdf")
        let content = try XCTUnwrap(blocks("labs_gut").first)
        XCTAssertTrue(content.hasPrefix("Gut microbiome report (collected 2026-05-14, 5 months ago) — Tiny Health:"), content)
    }

    func test_bloodwork_and_dexa_headers_carry_their_age() throws {
        save(.bloodwork(bloodwork(date: "2025-11-03", ldl: 118)), name: "bw.pdf")
        save(.dexa(MockPDFReports.mockDexaReport()), name: "dexa.pdf")
        let bw = try XCTUnwrap(blocks("labs_bloodwork").first)
        XCTAssertTrue(bw.hasPrefix("Latest bloodwork lab results (drawn 2025-11-03, 11 months ago) — Quest:"), bw)
        let dexa = try XCTUnwrap(blocks("labs_dexa").first)
        XCTAssertTrue(dexa.hasPrefix("Latest DEXA body composition scan (scanned "), dexa)
        XCTAssertTrue(dexa.contains(" ago)") || dexa.contains("today)"), dexa)
    }

    func test_an_undated_report_says_when_it_was_added_instead_of_claiming_today() throws {
        save(.gutHealth(try gut(date: nil, score: 50)), name: "gut.pdf")
        let content = try XCTUnwrap(blocks("labs_gut").first)
        XCTAssertTrue(content.contains("collected date not on the report; added to the app "), content)
    }

    func test_reports_are_ordered_by_their_real_date_whatever_the_format() throws {
        // As text, "2025-09-01" sorts after "05/14/2026"; by date it's older.
        save(.gutHealth(try gut(date: "2025-09-01", score: 40)), name: "old.pdf")
        save(.gutHealth(try gut(date: "05/14/2026", score: 61)), name: "new.pdf")
        let content = try XCTUnwrap(blocks("labs_gut").first)
        XCTAssertTrue(content.hasPrefix("Gut microbiome report (collected 2026-05-14, 5 months ago)"), content)
        XCTAssertTrue(content.contains("Earlier gut microbiome reports (newest first):\n  - collected 2025-09-01, 13 months ago — Tiny Health: microbiome score 40"), content)
    }

    // MARK: - Older reports

    func test_every_report_is_indexed_with_its_age() throws {
        save(.bloodwork(bloodwork(date: "2024-03-10", ldl: 150)), name: "a.pdf")
        save(.bloodwork(bloodwork(date: "2025-11-03", ldl: 118)), name: "b.pdf")
        save(.gutHealth(try gut(date: "2026-05-14", score: 61)), name: "gut.pdf")
        let index = try XCTUnwrap(blocks("labs_index").first)
        XCTAssertTrue(index.hasPrefix("Reports in the user's vault, newest first (3 total):"), index)
        XCTAssertTrue(index.contains("  - Gut microbiome: dated 2026-05-14, 5 months ago — Tiny Health"), index)
        XCTAssertTrue(index.contains("  - Bloodwork: dated 2025-11-03, 11 months ago — Quest (1 value)"), index)
        XCTAssertTrue(index.contains("  - Bloodwork: dated 2024-03-10, 2 years ago"), index)
    }

    func test_earlier_dexa_scans_reach_luma() throws {
        var older = MockPDFReports.mockDexaReport()
        older = DexaReportData(type: older.type, source: older.source, scanDate: "2024-12-01",
                               totalBodyFatPercent: 24.5, totalLeanMassKg: older.totalLeanMassKg,
                               visceralFatRating: older.visceralFatRating, visceralFatAreaCm2: older.visceralFatAreaCm2,
                               visceralFatVolumeCm3: older.visceralFatVolumeCm3, boneDensityTotal: older.boneDensityTotal,
                               androidGynoidRatio: older.androidGynoidRatio, regions: older.regions, notes: older.notes,
                               rawText: "older dexa", confidence: older.confidence)
        save(.dexa(MockPDFReports.mockDexaReport()), name: "new.pdf")
        save(.dexa(older), name: "old.pdf")
        let content = try XCTUnwrap(blocks("labs_dexa").first)
        XCTAssertTrue(content.contains("Earlier DEXA scans (newest first):\n  - scanned 2024-12-01, 22 months ago: body fat 24.5%"), content)
    }

    func test_bloodwork_history_keeps_five_draws_with_their_ages() throws {
        for (i, (date, ldl)) in [("2023-01-10", 160.0), ("2024-01-10", 150), ("2025-06-01", 131),
                                 ("2025-12-01", 110), ("2026-05-21", 98)].enumerated() {
            save(.bloodwork(bloodwork(date: date, ldl: ldl)), name: "\(i).pdf")
        }
        let trends = try XCTUnwrap(blocks("labs_trends").first)
        XCTAssertTrue(trends.contains("LDL Cholesterol: 98 mg/dL (2026-05-21) ← 110 mg/dL (2025-12-01) ← 131 mg/dL (2025-06-01) ← 150 mg/dL (2024-01-10) ← 160 mg/dL (2023-01-10)"), trends)
        XCTAssertTrue(trends.contains("Draw dates: 2026-05-21, 5 months ago; 2025-12-01, 10 months ago;"), trends)
    }

    func test_an_older_report_in_a_named_period_is_shown_in_full() throws {
        save(.bloodwork(bloodwork(date: "2024-03-10", ldl: 150)), name: "a.pdf")
        save(.bloodwork(bloodwork(date: "2026-05-21", ldl: 98)), name: "b.pdf")
        let periods = LumaPeriodResolver.resolve("what did my bloodwork look like in 2024?", now: now, calendar: calendar)
        let blocks = HealthContextBuilder.historyBlocks(periods: periods, keys: [], now: now)
        let full = try XCTUnwrap(blocks.first { $0.type == "labs_period" }?.content)
        XCTAssertTrue(full.hasPrefix("Bloodwork lab results (drawn 2024-03-10, 2 years ago) — Quest:"), full)
        XCTAssertTrue(full.contains("LDL Cholesterol: 150.0 mg/dL"), full)
    }

    // MARK: - Periods named in a message

    private func periods(_ text: String) -> [(String, String)] {
        LumaPeriodResolver.resolve(text, now: now, calendar: calendar).map {
            (LumaDate.day($0.start, calendar: calendar), LumaDate.day($0.end, calendar: calendar))
        }
    }

    func test_named_periods_resolve_to_dates() {
        XCTAssertEqual(periods("how was my sleep in March?").first?.0, "2026-03-01")
        XCTAssertEqual(periods("how was my sleep in March?").first?.1, "2026-03-31")
        XCTAssertEqual(periods("HRV in November").first?.0, "2025-11-01", "a month not yet reached this year is last year's")
        XCTAssertEqual(periods("steps in March 2025").first?.0, "2025-03-01")
        XCTAssertEqual(periods("since May").first?.0, "2026-05-01")
        XCTAssertEqual(periods("since May").first?.1, "2026-10-21")
        XCTAssertEqual(periods("last summer").first?.0, "2026-06-01")
        XCTAssertEqual(periods("last summer").first?.1, "2026-08-31")
        XCTAssertEqual(periods("3 months ago").first?.0, "2026-07-01")
        XCTAssertEqual(periods("last month").first?.0, "2026-09-01")
        XCTAssertEqual(periods("last month").first?.1, "2026-09-30")
        XCTAssertEqual(periods("over the past 6 months").first?.0, "2026-04-21")
        XCTAssertEqual(periods("around March 14").first?.0, "2026-03-11")
        XCTAssertEqual(periods("my 2025 bloodwork").first?.0, "2025-01-01")
        XCTAssertEqual(periods("my 2025 bloodwork").first?.1, "2025-12-31")
        XCTAssertEqual(periods("compare March 2025 with last month").count, 2)
    }

    func test_ordinary_words_and_numbers_are_not_periods() {
        XCTAssertTrue(periods("I may be overtraining").isEmpty)
        XCTAssertTrue(periods("I walked 2000 steps").isEmpty)
        XCTAssertTrue(periods("how did I sleep last night?").isEmpty)
        XCTAssertTrue(periods("we need to march on").isEmpty)
    }

    // MARK: - Long-term history

    private func seedDailyMetrics(from start: Date, days: Int) throws {
        let vault = try XCTUnwrap(LocalVault.shared.database)
        var rows: [DailyMetricRow] = []
        for i in 0..<days {
            let d = calendar.date(byAdding: .day, value: i, to: start)!
            let key = LumaDate.day(d, calendar: calendar)
            let month = calendar.component(.month, from: d)
            rows.append(DailyMetricRow(day: key, metric: "hrv_sdnn", avg: Double(40 + month), count: 10, source: .healthKit))
            rows.append(DailyMetricRow(day: key, metric: "steps", total: 8000, count: 10, source: .healthKit))
        }
        try vault.upsertDailyMetrics(rows, policy: .overwrite)
    }

    func test_history_reaches_back_by_month_and_year() throws {
        try seedDailyMetrics(from: day(2024, 1, 1), days: 1025)  // to 2026-10-21
        let vault = try XCTUnwrap(LocalVault.shared.database)
        let text = try XCTUnwrap(LumaHistoryBuilder(vault: vault, now: now, calendar: calendar).monthlyHistory(keys: ["hrv"]))
        XCTAssertTrue(text.contains("Vault data runs 2024-01-01 to 2026-10-21"), text)
        XCTAssertTrue(text.contains("- HRV, ms: by year 2024 47, 2025 (Jan–Sep) 45;"), text)
        XCTAssertTrue(text.contains("by month Oct 2025 50, Nov 2025 51, Dec 2025 52, Jan 2026 41"), text)
        XCTAssertTrue(text.contains("Oct 2026* 50"), text)
        XCTAssertFalse(text.contains("Steps"), "quick mode keeps the history to the question's metrics")
    }

    func test_a_named_period_gets_its_daily_values() throws {
        try seedDailyMetrics(from: day(2026, 3, 1), days: 31)
        let vault = try XCTUnwrap(LocalVault.shared.database)
        let period = try XCTUnwrap(LumaPeriodResolver.resolve("my HRV in March", now: now, calendar: calendar).first)
        let text = LumaHistoryBuilder(vault: vault, now: now, calendar: calendar).periodDetail(period, keys: nil)
        XCTAssertTrue(text.hasPrefix("Wearable data for March 2026: 2026-03-01 to 2026-03-31 (6 months ago at its end):"), text)
        XCTAssertTrue(text.contains("- HRV, ms: avg 43 over 31 days; Mar 1 43, Mar 2 43"), text)
        XCTAssertTrue(text.contains("- Steps/day: avg 8000 over 31 days"), text)
    }

    func test_a_period_without_data_says_so() throws {
        let vault = try XCTUnwrap(LocalVault.shared.database)
        let period = try XCTUnwrap(LumaPeriodResolver.resolve("in March 2022", now: now, calendar: calendar).first)
        let text = LumaHistoryBuilder(vault: vault, now: now, calendar: calendar).periodDetail(period, keys: nil)
        XCTAssertTrue(text.contains("No wearable data in the vault for this period. Don't estimate values for it."), text)
    }

    func test_context_for_a_message_naming_a_period_includes_it() throws {
        try seedDailyMetrics(from: day(2026, 3, 1), days: 31)
        let ctx = HealthContextBuilder.buildContext(for: .recovery, mode: .quick, message: "how was my HRV in March?")
        let types = (ctx?.contextBlocks ?? []).map(\.type)
        XCTAssertTrue(types.contains("period"), "\(types)")
        XCTAssertTrue(types.contains("history"), "\(types)")
        XCTAssertEqual(types.first, "data_note")
    }

    // MARK: - Metrics and guide

    func test_latest_values_name_their_day_and_trends_are_direction_only() {
        let fourDaysAgo = calendar.date(byAdding: .day, value: -4, to: Date())!
        let rhr = MetricContext(average: 52, min: nil, max: nil, latest: 55, sevenDayAvg: 54,
                                trend: "rising (+8%)", latestDate: fourDaysAgo)
        let metrics = AIChatMetrics(steps: nil, heartRate: nil, hrv: nil, sleep: nil, exercise: nil,
                                    restingHeartRate: rhr, vo2Max: nil, respiratoryRate: nil, recoveryScore: nil,
                                    sleepDeepHours: nil, sleepRemHours: nil)
        let text = HealthContextBuilder.formatMetrics(metrics, dateRange: AIChatDateRange(start: "a", end: "b"))
        XCTAssertTrue(text.contains("- Resting Heart Rate: 55 bpm ("), text)
        XCTAssertTrue(text.contains(", 4 days ago), 7-day avg 54 bpm, 30-day avg 52 bpm (trend: rising (+8%))"), text)
        XCTAssertFalse(text.contains("improving"), text)
    }

    func test_the_guide_says_how_to_treat_old_snapshots() {
        let guide = HealthContextBuilder.dataGuide(now: now, calendar: calendar)
        XCTAssertTrue(guide.hasPrefix("User's local time now: Wednesday 21 October 2026, 12:00"), guide)
        XCTAssertTrue(guide.contains("run 2026-09-21 to 2026-10-20"), guide)
        XCTAssertTrue(guide.contains("never estimate how old a report is"), guide)
        XCTAssertTrue(guide.contains("A report older than about 3 months is background"), guide)
    }

    // MARK: - Routing

    func test_mixed_questions_reach_every_topic_they_touch() {
        let intents = ChatIntentClassifier.classifyAll("how does my gut health relate to my sleep?")
        XCTAssertTrue(intents.contains(.labs), "\(intents)")
        XCTAssertTrue(intents.contains(.sleep), "\(intents)")
        XCTAssertEqual(ChatIntentClassifier.classify("I'm interested in what you remember"), .general,
                       "'rest' and 'rem' only match as words")
        XCTAssertEqual(ChatIntentClassifier.classify("show me my workouts"), .activity)
    }

    func test_quick_mode_keeps_labs_for_a_mixed_question() throws {
        save(.gutHealth(try gut(date: "2026-05-14", score: 61)), name: "gut.pdf")
        let intents = ChatIntentClassifier.classifyAll("how does my gut health relate to my sleep?")
        let ctx = HealthContextBuilder.buildContext(for: intents[0], mode: .quick, message: nil, intents: Set(intents))
        XCTAssertTrue((ctx?.contextBlocks ?? []).contains { $0.type == "labs_gut" })
    }

    // MARK: - Live evaluation fixture (opt-in)

    /// Fills the vault with a realistic made-up profile and writes, for each
    /// question, the exact request the app would send to /api/ai/chat.
    /// Set TEST_RUNNER_LUMA_EVAL_DIR to a folder; skipped otherwise.
    func test_write_luma_eval_requests() async throws {
        guard let out = ProcessInfo.processInfo.environment["LUMA_EVAL_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_LUMA_EVAL_DIR")
        }
        let vault = try XCTUnwrap(LocalVault.shared.database)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // ~2 years of daily data. Baseline HRV 55, a strong March 2026 (63),
        // and a dip over the last 14 days: HRV ~42, RHR up, sleep down.
        var rows: [DailyMetricRow] = []
        var d = day(2024, 9, 1)
        var i = 0
        while d <= today {
            let key = LumaDate.day(d)
            let daysAgo = cal.dateComponents([.day], from: d, to: today).day ?? 0
            let month = cal.component(.month, from: d), year = cal.component(.year, from: d)
            let wiggle = Double((i * 37) % 9) - 4
            let recentDip = daysAgo <= 14
            let strongMarch = year == 2026 && month == 3
            let hrv = recentDip ? 42 + wiggle / 2 : (strongMarch ? 63 + wiggle : 55 + wiggle)
            let rhr = recentDip ? 58 + wiggle / 4 : (strongMarch ? 51 + wiggle / 4 : 54 + wiggle / 4)
            let sleepMin = (recentDip ? 6.3 : (strongMarch ? 7.6 : 7.2)) * 60 + wiggle * 4
            rows.append(DailyMetricRow(day: key, metric: "hrv_sdnn", avg: hrv, min: hrv - 15, max: hrv + 20, count: 30, source: .healthKit))
            rows.append(DailyMetricRow(day: key, metric: "resting_heart_rate", avg: rhr, count: 1, source: .healthKit))
            rows.append(DailyMetricRow(day: key, metric: "heart_rate", avg: rhr + 16, min: rhr - 4, max: 150, count: 400, source: .healthKit))
            rows.append(DailyMetricRow(day: key, metric: "steps", total: 9000 + wiggle * 600, count: 100, source: .healthKit))
            rows.append(DailyMetricRow(day: key, metric: "exercise_minutes", total: 35 + wiggle * 3, count: 20, source: .healthKit))
            rows.append(DailyMetricRow(day: key, metric: "active_energy", total: 600 + wiggle * 30, count: 100, source: .healthKit))
            rows.append(DailyMetricRow(day: key, metric: "respiratory_rate", avg: 14.5, count: 10, source: .healthKit))
            if i % 10 == 0 {
                rows.append(DailyMetricRow(day: key, metric: "vo2_max", avg: 46 + Double(year - 2024) * 0.8, count: 1, source: .healthKit))
            }
            var sleep = DailyMetricRow(day: key, metric: AmachMetric.sleepId, total: sleepMin, count: 1, source: .healthKit)
            sleep.sleepDeepMin = sleepMin * 0.16
            sleep.sleepRemMin = sleepMin * 0.22
            sleep.sleepCoreMin = sleepMin * 0.62
            rows.append(sleep)
            d = cal.date(byAdding: .day, value: 1, to: d)!
            i += 1
        }
        try vault.upsertDailyMetrics(rows, policy: .overwrite)

        // Reports: gut test May 2026; bloodwork and DEXA Nov 2025; older ones 2024.
        func bw(_ date: String, _ markers: [(String, Double, String, String?)]) -> BloodworkReportData {
            BloodworkReportData(type: "bloodwork", source: "Quest", reportDate: date, laboratory: "Quest Diagnostics", panels: [:],
                                metrics: markers.map { BloodworkMetric(name: $0.0, value: $0.1, valueText: nil, unit: $0.2,
                                                                       referenceRange: $0.3, panel: nil, collectedAt: nil, flag: nil,
                                                                       interpretationNotes: nil) },
                                notes: nil, rawText: "eval bw \(date)", confidence: 1)
        }
        save(.bloodwork(bw("2024-06-12", [("LDL Cholesterol", 135, "mg/dL", "<100"), ("HDL Cholesterol", 48, "mg/dL", ">39"),
                                          ("Hemoglobin A1c", 5.6, "%", "<5.7"), ("Glucose", 98, "mg/dL", "65-99"),
                                          ("Vitamin D, 25-OH", 26, "ng/mL", "30-100"), ("hs-CRP", 2.4, "mg/L", "<1.0")])), name: "bw2024.pdf")
        save(.bloodwork(bw("2025-11-03", [("LDL Cholesterol", 118, "mg/dL", "<100"), ("HDL Cholesterol", 52, "mg/dL", ">39"),
                                          ("Apolipoprotein B", 95, "mg/dL", "<90"), ("Hemoglobin A1c", 5.4, "%", "<5.7"),
                                          ("Glucose", 92, "mg/dL", "65-99"), ("Vitamin D, 25-OH", 34, "ng/mL", "30-100"),
                                          ("hs-CRP", 1.8, "mg/L", "<1.0"), ("Ferritin", 140, "ng/mL", "38-380"),
                                          ("Testosterone, Total", 610, "ng/dL", "250-1100")])), name: "bw2025.pdf")
        let base = MockPDFReports.mockDexaReport()
        func dexa(_ date: String, fat: Double, lean: Double) -> DexaReportData {
            DexaReportData(type: "dexa", source: "BodySpec", scanDate: date, totalBodyFatPercent: fat, totalLeanMassKg: lean,
                           visceralFatRating: nil, visceralFatAreaCm2: nil, visceralFatVolumeCm3: nil,
                           boneDensityTotal: base.boneDensityTotal, androidGynoidRatio: 0.95, regions: [], notes: nil,
                           rawText: "eval dexa \(date)", confidence: 1)
        }
        save(.dexa(dexa("2024-07-01", fat: 21.5, lean: 61.8)), name: "dexa2024.pdf")
        save(.dexa(dexa("2025-11-10", fat: 18.2, lean: 64.1)), name: "dexa2025.pdf")
        let gut = try XCTUnwrap(GutHealthReport(json: [
            "provider": "Tiny Health", "collection_date": "2026-05-14",
            "summary": ["microbiome_score": 58, "gut_type": "Bacteroides-dominant"],
            "other_metrics": [
                ["name": "Butyrate producers", "value": 4.1, "unit": "%", "section": "Gut barrier & inflammation", "status": "needs_support"],
                ["name": "Akkermansia muciniphila", "value": 0.02, "unit": "%", "section": "Gut barrier & inflammation", "status": "needs_improving"],
                ["name": "Species diversity", "value": 3.2, "unit": "Shannon", "section": "Diversity", "status": "good"],
            ],
            "species": [["name": "Bacteroides uniformis", "abundance_pct": 11.2, "classification": "beneficial"],
                        ["name": "Prevotella copri", "abundance_pct": 6.4, "classification": "variable"]],
        ]))
        save(.gutHealth(gut), name: "gut.pdf")

        // Memory from earlier conversations.
        let aug = cal.date(byAdding: .month, value: -2, to: today)!
        ConversationMemoryStore.shared.upsert(
            facts: [CriticalFact(id: UUID(), category: .medication, value: "Takes magnesium glycinate 400 mg at night",
                                 context: nil, dateIdentified: aug, isActive: true, lastConfirmed: nil),
                    CriticalFact(id: UUID(), category: .goal, value: "Get body fat under 15%",
                                 context: nil, dateIdentified: aug, isActive: true, lastConfirmed: nil)],
            summary: SessionSummary(id: UUID(), date: aug, summary: "Discussed raising vitamin D with supplements.",
                                    topics: ["vitamin d"], importance: .medium, messageCount: 6))

        // The dashboard as the app shows it, read from this vault.
        let reader = VaultDashboardReader(vault: vault)
        let dash = DashboardService.shared
        dash.today = reader.today()
        dash.stepsTrend = reader.allPeriods("steps")
        dash.heartRateTrend = reader.allPeriods("heart_rate")
        dash.hrvTrend = reader.allPeriods("hrv_sdnn")
        dash.exerciseTrend = reader.allPeriods("exercise_minutes")
        dash.rhrTrend = reader.allPeriods("resting_heart_rate")
        dash.rrTrend = reader.allPeriods("respiratory_rate")
        dash.vo2Trend = reader.allPeriods("vo2_max")
        dash.sleepTrend = Dictionary(uniqueKeysWithValues: TrendPeriod.allCases.map { ($0, reader.sleepTrend(days: $0.days)) })
        dash.sleepStagesTrend = Dictionary(uniqueKeysWithValues: TrendPeriod.allCases.map { ($0, reader.sleepStagesTrend(days: $0.days)) })

        let questions: [(id: String, mode: ChatMode, text: String)] = [
            ("gut_age", .quick, "How old is my gut health test, and what did it show?"),
            ("hrv_drop", .quick, "Why has my HRV dropped over the last couple of weeks?"),
            ("body_now", .quick, "How does my body composition look right now?"),
            ("sleep_march", .quick, "How was my sleep in March compared to now?"),
            ("ldl_trend", .quick, "Has my LDL improved over time?"),
            ("hrv_years", .quick, "Compare my HRV this year to last year."),
            ("vitd_2024", .quick, "What was my vitamin D in 2024?"),
            ("no_data", .quick, "How was my recovery in March 2023?"),
            ("gut_sleep", .quick, "Is my gut health related to how I've been sleeping lately?"),
            ("summary_deep", .deep, "Give me an overall health summary."),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Request: Encodable {
            let id: String; let message: String; let context: AIChatContext; let history: [AIChatHistoryMessage]
            let options: [String: String]
        }
        for q in questions {
            let intents = ChatIntentClassifier.classifyAll(q.text)
            var blocks = HealthContextBuilder.buildContext(for: intents[0], mode: q.mode, message: q.text,
                                                           intents: Set(intents))?.contextBlocks ?? []
            // As ChatService.enrichContext adds it.
            if let mem = ConversationMemoryStore.shared.buildMemoryCapsule(intent: intents[0], mode: q.mode) {
                blocks.append(ContextBlock(type: "memory", content: HealthContextBuilder.formatMemory(
                    mem, latestBloodwork: LabContextService.shared.currentContext()?.bloodwork?.reportDate)))
            }
            let request = Request(id: q.id, message: q.text, context: AIChatContext(contextBlocks: blocks),
                                  history: [], options: ["mode": q.mode.rawValue])
            let url = URL(fileURLWithPath: out).appendingPathComponent("\(q.id).json")
            try encoder.encode(request).write(to: url)
        }
    }

    // MARK: - Memory

    func test_memory_reaches_the_backend_as_a_dated_block() async throws {
        let api = MockAmachAPIClient()
        let sut = ChatService(injectedAPI: api, injectedWallet: MockWalletService())
        ConversationMemoryStore.shared.upsert(
            facts: [CriticalFact(id: UUID(), category: .medication, value: "takes magnesium at night", context: nil,
                                 dateIdentified: Date(), isActive: true, lastConfirmed: nil)],
            summary: SessionSummary(id: UUID(), date: Date(), summary: "Talked about sleep.", topics: ["sleep"],
                                    importance: .medium, messageCount: 4))
        await sut.send("what supplements am I on?")
        let memory = try XCTUnwrap(api.lastChatContext?.contextBlocks?.first { $0.type == "memory" }?.content)
        XCTAssertTrue(memory.contains("takes magnesium at night (noted "), memory)
        XCTAssertTrue(memory.contains("(today): Talked about sleep."), memory)
    }

    func test_memory_says_notes_after_the_latest_draw_havent_been_tested() {
        let mem = AIChatMemoryCapsule(activeGoals: [], activeConcerns: [], medications: ["Vitamin D 2000 IU (noted Aug 2026)"],
                                      conditions: [], recentSessionNotes: [])
        let text = HealthContextBuilder.formatMemory(mem, latestBloodwork: "11/03/2025")
        XCTAssertTrue(text.contains("Latest bloodwork was drawn 2025-11-03. Anything noted after that date"), text)
    }

    // MARK: - Memory across chats

    private static let factsJSON = #"{"facts":[{"category":"medication","value":"Takes creatine 5 g daily","context":"chat"}]}"#

    /// Answers the two extraction prompts; anything else gets a plain reply.
    private func memoryAPI(facts: String = factsJSON, summary: String = "Talked about creatine.") -> MockAmachAPIClient {
        let api = MockAmachAPIClient()
        api.config.chatResponder = { prompt in
            if prompt.contains("Analyze the conversation and extract") { return facts }
            if prompt.contains("Create a brief summary") {
                return #"{"summary":"\#(summary)","topics":["supplements"],"importance":"medium"}"#
            }
            return nil
        }
        return api
    }

    private func extractionPrompts(_ api: MockAmachAPIClient) -> [String] {
        api.sentChatMessages.filter { $0.contains("Analyze the conversation and extract") }
    }

    func test_memory_builds_without_new_chat() async throws {
        let api = memoryAPI()
        let sut = ChatService(injectedAPI: api, injectedWallet: MockWalletService(), injectedVault: LocalVault.shared.database)
        let memory = ConversationMemoryStore.shared

        for i in 1..<ChatService.memoryExtractionInterval {
            await sut.send("Question \(i) about my creatine and training")
        }
        XCTAssertNil(sut.memoryExtractionTask, "nothing read before the interval")
        XCTAssertTrue(extractionPrompts(api).isEmpty)

        await sut.send("I take 5 g of creatine every morning")
        await sut.memoryExtractionTask?.value

        let session = sut.currentSession
        XCTAssertEqual(session.messages.count, 20, "still the same session: no New Chat")
        XCTAssertTrue(memory.facts.contains { $0.value == "Takes creatine 5 g daily" && $0.isActive })
        XCTAssertEqual(memory.summaries.map(\.id), [session.id], "the summary belongs to this session")
        XCTAssertEqual(memory.extractedMessageCount(sessionId: session.id), 20)

        // Progress is kept in the vault.
        memory.vaultDidChange()
        XCTAssertEqual(memory.extractedMessageCount(sessionId: session.id), 20)
        XCTAssertEqual(memory.summaries.count, 1)
    }

    func test_later_extractions_read_only_new_messages_and_update_the_summary() async throws {
        let api = memoryAPI(summary: "First part: creatine.")
        let sut = ChatService(injectedAPI: api, injectedWallet: MockWalletService(), injectedVault: LocalVault.shared.database)
        let memory = ConversationMemoryStore.shared

        await sut.send("I started creatine 5 g a day for training")
        await sut.extractCurrentSessionMemory()
        XCTAssertEqual(memory.summaries.first?.summary, "First part: creatine.")

        // Nothing new: no second extraction.
        await sut.extractCurrentSessionMemory()
        XCTAssertEqual(extractionPrompts(api).count, 1)

        api.config.chatResponder = memoryAPI(facts: #"{"facts":[]}"#, summary: "Creatine, then sleep.").config.chatResponder
        await sut.send("Also my sleep has been poor this week, around five hours")
        await sut.extractCurrentSessionMemory()

        let prompts = extractionPrompts(api)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertFalse(prompts[1].contains("I started creatine"), "already read")
        XCTAssertTrue(prompts[1].contains("sleep has been poor"))
        let summaryPrompt = try XCTUnwrap(api.sentChatMessages.last { $0.contains("Create a brief summary") })
        XCTAssertTrue(summaryPrompt.contains("Summary of this conversation so far:\nFirst part: creatine."), summaryPrompt)

        XCTAssertEqual(memory.summaries.count, 1, "updated, not appended")
        XCTAssertEqual(memory.summaries.first?.summary, "Creatine, then sleep.")
        XCTAssertEqual(memory.summaries.first?.messageCount, 4)

        // Archiving the session afterwards adds no second summary.
        let session = sut.currentSession
        await sut.summarizeAndArchive(session)
        XCTAssertEqual(extractionPrompts(api).count, 2)
        memory.vaultDidChange()
        XCTAssertEqual(memory.summaries.map(\.id), [session.id])
    }

    func test_extraction_retires_facts_that_no_longer_hold() async throws {
        let memory = ConversationMemoryStore.shared
        memory.upsert(
            facts: [CriticalFact(id: UUID(), category: .medication, value: "Takes magnesium glycinate 400 mg at night",
                                 context: nil, dateIdentified: Date(), isActive: true, lastConfirmed: nil),
                    CriticalFact(id: UUID(), category: .goal, value: "Sleep 8 hours a night",
                                 context: nil, dateIdentified: Date(), isActive: true, lastConfirmed: nil)],
            summary: nil)
        let api = memoryAPI(facts: #"{"facts":[{"category":"medication","value":"Takes zinc 15 mg"}],"retire":["F1"]}"#)
        let sut = ChatService(injectedAPI: api, injectedWallet: MockWalletService(), injectedVault: LocalVault.shared.database)

        var session = ChatSession()
        session.messages = [ChatMessage(role: .user, content: "I stopped the magnesium last week, it upset my stomach. Trying zinc."),
                            ChatMessage(role: .assistant, content: "Noted.")]
        await sut.extractSessionMemory(from: session)

        let prompt = try XCTUnwrap(extractionPrompts(api).first)
        XCTAssertTrue(prompt.contains("F1 [medication] Takes magnesium glycinate 400 mg at night"), prompt)
        XCTAssertTrue(prompt.contains(#""retire""#))

        let magnesium = try XCTUnwrap(memory.facts.first { $0.value.contains("magnesium") })
        XCTAssertFalse(magnesium.isActive)
        XCTAssertNotNil(magnesium.retiredAt)
        XCTAssertTrue(memory.facts.contains { $0.value == "Sleep 8 hours a night" && $0.isActive })

        let capsule = try XCTUnwrap(memory.buildMemoryCapsule(mode: .deep))
        let block = HealthContextBuilder.formatMemory(capsule)
        XCTAssertFalse(block.contains("magnesium"), block)
        XCTAssertTrue(block.contains("Takes zinc 15 mg"), block)

        // Retirement survives a reload from the vault.
        memory.vaultDidChange()
        XCTAssertEqual(memory.facts.first { $0.value.contains("magnesium") }?.isActive, false)
    }

    func test_preferences_reach_the_memory_block() async throws {
        ConversationMemoryStore.shared.upsert(
            facts: [CriticalFact(id: UUID(), category: .preference, value: "Prefers food-first advice over supplements",
                                 context: nil, dateIdentified: Date(), isActive: true, lastConfirmed: nil)],
            summary: nil)
        let api = MockAmachAPIClient()
        let sut = ChatService(injectedAPI: api, injectedWallet: MockWalletService())
        // A sleep question: preferences come along whatever the topic.
        await sut.send("how did I sleep last night?")
        let memory = try XCTUnwrap(api.lastChatContext?.contextBlocks?.first { $0.type == "memory" }?.content)
        XCTAssertTrue(memory.contains("Preferences: Prefers food-first advice over supplements (noted "), memory)
    }

    func test_memory_carries_older_notes_on_the_question_topic() {
        func summary(_ text: String, topics: [String], daysAgo: Int) -> SessionSummary {
            SessionSummary(id: UUID(), date: calendar.date(byAdding: .day, value: -daysAgo, to: now)!, summary: text,
                           topics: topics, importance: .medium, messageCount: 4)
        }
        let all = [
            summary("Worked out why deep sleep drops after late dinners.", topics: ["sleep"], daysAgo: 150),
            summary("Discussed LDL and the cholesterol panel.", topics: ["labs"], daysAgo: 120),
            summary("Set a step target for walking.", topics: ["activity"], daysAgo: 30),
            summary("Reviewed vitamin D dosing.", topics: ["supplements"], daysAgo: 20),
            summary("Planned a zone 2 cardio block.", topics: ["training"], daysAgo: 10),
        ]
        let sleep = ConversationMemoryStore.pickSummaries(all, intent: .sleep, mode: .quick).map(\.summary)
        XCTAssertEqual(sleep.first, "Worked out why deep sleep drops after late dinners.")
        XCTAssertEqual(sleep.count, 4, "3 most recent + the older one on sleep")
        XCTAssertFalse(sleep.contains("Discussed LDL and the cholesterol panel."))

        let general = ConversationMemoryStore.pickSummaries(all, intent: .general, mode: .quick)
        XCTAssertEqual(general.count, 3)
        XCTAssertEqual(ConversationMemoryStore.pickSummaries(all, intent: nil, mode: .deep).count, 5)
    }
}
