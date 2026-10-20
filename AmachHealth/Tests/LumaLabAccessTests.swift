// LumaLabAccessTests.swift
// AmachHealthTests
//
// A report saved through PDF import must reach Luma: its values appear in
// the labs blocks of the next message's context, a newer report replaces the
// older one, and this works before any health metrics have loaded. Earlier
// values of repeating markers, DEXA regions and medical documents reach Luma
// too, within size caps and quick-mode pruning.
//
// Optional real-data check: set TEST_RUNNER_AMACH_LIVE_REPORT_JSON to one or
// more parse-report responses (colon-separated paths). Only counts are
// printed, never values.

import XCTest
import GRDB
@testable import AmachHealth

@MainActor
final class LumaLabAccessTests: XCTestCase {

    private var dir: URL!
    private let service = PDFUploadService.shared

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("luma-labs-\(UUID().uuidString)")
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

    private func save(_ report: ParsedHealthReport, name: String = "report.pdf") {
        // Distinct bytes per report so the kept PDFs don't collide.
        var pdf = MockPDFReports.mockBloodworkPDF()
        pdf.append(Data(name.utf8))
        service.save(PDFReadResult(report: report, reader: .privateAI(model: "test"), filename: name,
                                   pdfData: pdf, seconds: 1))
        guard case .done = service.state else { return XCTFail("save failed: \(service.state)") }
    }

    private func block(_ type: String, intent: ChatIntent = .labs, mode: ChatMode = .quick) -> String? {
        HealthContextBuilder.buildContext(for: intent, mode: mode)?
            .contextBlocks?.first { $0.type == type }?.content
    }

    private func bloodwork(date: String, ldl: Double) -> BloodworkReportData {
        let base = MockPDFReports.mockBloodworkReport()
        let metrics = base.metrics.map { m in
            m.name == "LDL Cholesterol"
                ? BloodworkMetric(name: m.name, value: ldl, valueText: nil, unit: m.unit, referenceRange: m.referenceRange,
                                  panel: m.panel, collectedAt: nil, flag: m.flag, interpretationNotes: nil)
                : m
        }
        return BloodworkReportData(type: "bloodwork", source: base.source, reportDate: date, laboratory: base.laboratory,
                                   panels: [:], metrics: metrics, notes: nil, rawText: "fingerprint \(date) \(ldl)",
                                   confidence: 1)
    }

    func test_imported_bloodwork_reaches_luma_even_before_health_metrics_load() throws {
        XCTAssertEqual(DashboardService.shared.today.steps, 0, "precondition: no metrics loaded")
        let report = MockPDFReports.mockBloodworkReport()
        save(.bloodwork(report))

        let content = try XCTUnwrap(block("labs_bloodwork"), "Luma got no bloodwork block")
        for metric in report.metrics {
            XCTAssertTrue(content.contains(metric.name), "missing \(metric.name)")
        }
    }

    func test_a_newer_import_replaces_what_luma_saw() throws {
        save(.bloodwork(bloodwork(date: "2025-06-01", ldl: 131)), name: "old.pdf")
        XCTAssertTrue(try XCTUnwrap(block("labs_bloodwork")).contains("2025-06-01"))

        save(.bloodwork(bloodwork(date: "2026-05-21", ldl: 98)), name: "new.pdf")
        let content = try XCTUnwrap(block("labs_bloodwork"))
        XCTAssertTrue(content.contains("2026-05-21"), "Luma still sees the older report")
        XCTAssertTrue(content.contains("LDL Cholesterol: 98"), content)
    }

    func test_imported_dexa_reaches_luma() throws {
        save(.dexa(MockPDFReports.mockDexaReport()), name: "dexa.pdf")
        let content = try XCTUnwrap(block("labs_dexa", intent: .bodyComp), "Luma got no DEXA block")
        if let fat = MockPDFReports.mockDexaReport().totalBodyFatPercent {
            XCTAssertTrue(content.contains("Body fat: \(fat)%"), content)
        }
    }

    func test_lab_data_context_works_with_the_vault_and_no_live_wallet_session() async throws {
        XCTAssertFalse(WalletService.shared.isConnected, "precondition: no Privy session in tests")
        save(.bloodwork(MockPDFReports.mockBloodworkReport()))
        let labData = await HealthContextBuilder.buildLabContext()
        XCTAssertNotNil(labData?.bloodwork, "vault opened offline: lab data should still reach Luma")
    }

    private func medical(title: String, date: String, summary: String?) -> MedicalRecordData {
        MedicalRecordData(type: "medical-record", source: "Clinic", reportDate: date, documentType: "imaging",
                          title: title, summary: summary, keyFindings: ["Mild degenerative change at L4-L5"],
                          medications: ["Ibuprofen 400 mg as needed"], diagnoses: ["Lumbar spondylosis"],
                          rawText: "medical \(title) \(date)", confidence: 0.9)
    }

    private func bloodwork(date: String, markers: [(String, Double)]) -> BloodworkReportData {
        let metrics = markers.map {
            BloodworkMetric(name: $0.0, value: $0.1, valueText: nil, unit: "mg/dL", referenceRange: nil,
                            panel: nil, collectedAt: nil, flag: nil, interpretationNotes: nil)
        }
        return BloodworkReportData(type: "bloodwork", source: "Lab", reportDate: date, laboratory: nil, panels: [:],
                                   metrics: metrics, notes: nil, rawText: "custom \(date) \(markers.count)", confidence: 1)
    }

    // MARK: - History, regions, medical documents

    func test_repeating_markers_reach_luma_with_their_last_three_values() throws {
        save(.bloodwork(bloodwork(date: "2024-01-10", ldl: 150)), name: "a.pdf")
        save(.bloodwork(bloodwork(date: "2025-06-01", ldl: 131)), name: "b.pdf")
        save(.bloodwork(bloodwork(date: "2025-12-01", ldl: 110)), name: "c.pdf")
        save(.bloodwork(bloodwork(date: "2026-05-21", ldl: 98)), name: "d.pdf")

        let content = try XCTUnwrap(block("labs_trends"), "Luma got no bloodwork history")
        XCTAssertTrue(content.contains(
            "LDL Cholesterol: 98 mg/dL (2026-05-21) ← 110 mg/dL (2025-12-01) ← 131 mg/dL (2025-06-01)"), content)
        XCTAssertFalse(content.contains("2024-01-10"), "only the last 3 values per marker")
        XCTAssertTrue(content.contains("HbA1c: 5.2 %"), content)
    }

    func test_markers_measured_once_have_no_history() throws {
        save(.bloodwork(bloodwork(date: "2025-06-01", markers: [("Glucose", 90), ("Ferritin", 80)])), name: "a.pdf")
        XCTAssertNil(block("labs_trends"), "a single report has no history")

        save(.bloodwork(bloodwork(date: "2026-01-01", markers: [("Glucose", 95), ("Homocysteine", 9)])), name: "b.pdf")
        let content = try XCTUnwrap(block("labs_trends"))
        XCTAssertTrue(content.contains("Glucose: 95 mg/dL (2026-01-01) ← 90 mg/dL (2025-06-01)"), content)
        XCTAssertFalse(content.contains("Ferritin"), content)
        XCTAssertFalse(content.contains("Homocysteine"), content)
    }

    func test_bloodwork_history_is_capped() throws {
        let names = (1...80).map { "Very long marker name number \($0) for size testing" }
        save(.bloodwork(bloodwork(date: "2025-01-01", markers: names.map { ($0, 1) })), name: "a.pdf")
        save(.bloodwork(bloodwork(date: "2025-06-01", markers: names.map { ($0, 2) })), name: "b.pdf")
        save(.bloodwork(bloodwork(date: "2026-01-01", markers: names.map { ($0, 3) })), name: "c.pdf")

        let content = try XCTUnwrap(block("labs_trends"))
        XCTAssertLessThanOrEqual(content.count, HealthContextBuilder.maxTrendsChars + 40)
        let lines = content.split(separator: "\n").filter { $0.hasPrefix("  - ") }.count
        XCTAssertLessThanOrEqual(lines, LabContextService.maxTrendMarkers)
        XCTAssertTrue(content.contains("more not shown"), content)
        XCTAssertTrue(content.contains("number 1 for size testing: 3 mg/dL"), "latest report's markers come first")
    }

    func test_dexa_regions_reach_luma_next_to_the_totals() throws {
        save(.dexa(MockPDFReports.mockDexaReport()), name: "dexa.pdf")
        let content = try XCTUnwrap(block("labs_dexa", intent: .bodyComp))
        XCTAssertTrue(content.contains("Body fat: 17.0%"), content)
        XCTAssertTrue(content.contains("  - left arm: body fat 15.6%, lean 3.58 kg, fat 0.68 kg"), content)
        XCTAssertTrue(content.contains("  - trunk: body fat 15.6%, lean 29.65 kg, fat 5.62 kg"), content)
        for region in MockPDFReports.mockDexaReport().regions {
            XCTAssertTrue(content.contains("  - \(region.region):"), "missing \(region.region)")
        }
    }

    func test_medical_documents_reach_luma_and_non_medical_ones_do_not() throws {
        save(.medicalRecord(medical(title: "Lumbar MRI", date: "2026-03-02", summary: "MRI of the lower back.")),
             name: "mri.pdf")
        save(.medicalRecord(medical(title: "Gym invoice", date: "2026-04-01",
                                    summary: MedicalRecordData.noMedicalContentNote)), name: "invoice.pdf")

        let content = try XCTUnwrap(block("labs_medical"), "Luma got no medical documents")
        XCTAssertTrue(content.contains("Lumbar MRI [imaging] (2026-03-02)"), content)
        XCTAssertTrue(content.contains("Summary: MRI of the lower back."), content)
        XCTAssertTrue(content.contains("Findings: Mild degenerative change at L4-L5"), content)
        XCTAssertTrue(content.contains("Diagnoses: Lumbar spondylosis"), content)
        XCTAssertTrue(content.contains("Medications: Ibuprofen 400 mg as needed"), content)
        XCTAssertFalse(content.contains("Gym invoice"), content)
    }

    func test_medical_documents_are_limited_to_the_most_recent() throws {
        for i in 1...7 {
            save(.medicalRecord(medical(title: "Visit \(i)", date: "2026-0\(i)-01", summary: "Visit note \(i)")),
                 name: "visit-\(i).pdf")
        }
        let content = try XCTUnwrap(block("labs_medical"))
        XCTAssertTrue(content.contains("Visit 7"), content)
        XCTAssertFalse(content.contains("Visit 2 "), content)
        XCTAssertLessThanOrEqual(content.count, HealthContextBuilder.maxMedicalChars + 40)
    }

    func test_gut_report_reaches_luma_as_its_own_block() throws {
        let gut = try XCTUnwrap(GutHealthReport(json: [
            "provider": "Tiny Health", "collection_date": "2026-09-01",
            "summary": ["microbiome_score": 61],
            "other_metrics": [["name": "Cellulose", "value": 42, "unit": "rpkm", "section": "Digestive capacity"]],
            "species": [["name": "Phocaeicola dorei", "abundance_pct": 9.771, "classification": "variable"]],
        ]))
        save(.gutHealth(gut), name: "gut.pdf")
        let content = try XCTUnwrap(block("labs_gut"), "Luma got no gut block")
        XCTAssertTrue(content.contains("microbiome score 61"), content)
        XCTAssertTrue(content.contains("Cellulose 42 rpkm"), content)
        XCTAssertTrue(content.contains("Phocaeicola dorei 9.771% (variable)"), content)
        XCTAssertNil(block("labs_medical"), "a gut report is not listed as a medical document")
        XCTAssertNil(block("labs_gut", intent: .sleep), "quick mode drops it for unrelated questions")
    }

    func test_quick_mode_prunes_lab_history_by_intent_and_deep_mode_keeps_it() throws {
        save(.bloodwork(bloodwork(date: "2025-06-01", ldl: 131)), name: "a.pdf")
        save(.bloodwork(bloodwork(date: "2026-05-21", ldl: 98)), name: "b.pdf")
        save(.dexa(MockPDFReports.mockDexaReport()), name: "dexa.pdf")
        save(.medicalRecord(medical(title: "Lumbar MRI", date: "2026-03-02", summary: "MRI.")), name: "mri.pdf")

        let all = ["labs_bloodwork", "labs_trends", "labs_dexa", "labs_medical"]
        func types(_ intent: ChatIntent, _ mode: ChatMode) -> Set<String> {
            Set((HealthContextBuilder.buildContext(for: intent, mode: mode)?.contextBlocks ?? []).map(\.type))
                .intersection(all)
        }
        XCTAssertEqual(types(.labs, .quick), Set(all))
        XCTAssertEqual(types(.general, .quick), Set(all))
        XCTAssertEqual(types(.bodyComp, .quick), ["labs_bloodwork", "labs_dexa", "labs_medical"])
        XCTAssertEqual(types(.medications, .quick), ["labs_medical"])
        XCTAssertEqual(types(.sleep, .quick), [])
        XCTAssertEqual(types(.sleep, .deep), Set(all))
    }

    // MARK: - Real data (opt-in)

    func test_real_parse_results_reach_luma_whole() throws {
        guard let paths = ProcessInfo.processInfo.environment["AMACH_LIVE_REPORT_JSON"] else {
            throw XCTSkip("Set AMACH_LIVE_REPORT_JSON")
        }
        struct Response: Decodable { struct Item: Decodable { let report: Raw }; let reports: [Item] }
        struct Raw: Decodable { let type: String }
        for (i, path) in paths.split(separator: ":").enumerated() {
            let data = try Data(contentsOf: URL(fileURLWithPath: String(path)))
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let first = (json["reports"] as! [[String: Any]])[0]["report"]!
            let reportData = try JSONSerialization.data(withJSONObject: first)
            switch try JSONDecoder().decode(Raw.self, from: reportData).type {
            case "bloodwork":
                let bw = try JSONDecoder().decode(BloodworkReportData.self, from: reportData)
                save(.bloodwork(bw), name: "real-\(i).pdf")
                let content = try XCTUnwrap(block("labs_bloodwork"))
                let lines = content.split(separator: "\n").filter { $0.hasPrefix("  • ") }.count
                let withValues = bw.metrics.filter { $0.value != nil || !($0.valueText ?? "").isEmpty }.count
                print("LUMA_LAB_ACCESS bloodwork parsed=\(bw.metrics.count) withValues=\(withValues) inLumaBlock=\(lines)")
                XCTAssertEqual(lines, withValues, "values dropped between the vault and Luma")
            case "dexa":
                let dx = try JSONDecoder().decode(DexaReportData.self, from: reportData)
                save(.dexa(dx), name: "real-\(i).pdf")
                let content = try XCTUnwrap(block("labs_dexa", intent: .bodyComp))
                let lines = content.split(separator: "\n").filter { $0.hasPrefix("  • ") }.count
                let expected = [dx.totalBodyFatPercent, dx.totalLeanMassKg, dx.visceralFatRating, dx.androidGynoidRatio,
                                dx.boneDensityTotal?.tScore, dx.boneDensityTotal?.zScore].compactMap { $0 }.count
                print("LUMA_LAB_ACCESS dexa totals=\(expected) regions=\(dx.regions.count) inLumaBlock=\(lines)")
                XCTAssertEqual(lines, expected)
            default:
                XCTFail("unexpected report type in \(path)")
            }
        }
    }
}
