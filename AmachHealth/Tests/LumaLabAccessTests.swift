// LumaLabAccessTests.swift
// AmachHealthTests
//
// A report saved through PDF import must reach Luma: its values appear in
// the labs blocks of the next message's context, a newer report replaces the
// older one, and this works before any health metrics have loaded.
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
