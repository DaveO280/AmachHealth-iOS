// PDFImportFlowTests.swift
// AmachHealthTests
//
// PDF import reads first and saves only after review: an AI failure never
// saves anything, the offline reader is opt-in, and who read the report is
// carried through to the review screen.

import XCTest
import GRDB
@testable import AmachHealth

@MainActor
final class PDFImportFlowTests: XCTestCase {

    private var dir: URL!
    private let service = PDFUploadService.shared

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-flow-\(UUID().uuidString)")
        BackupService.autoRunEnabled = false
        StorjImportService.autoRunEnabled = false
        let key = WalletEncryptionKey(walletAddress: WalletDecryptorFixtures.walletAddress,
                                      encryptionKey: WalletDecryptorFixtures.encryptionKey, signature: "0x", timestamp: 0)
        LocalVault.shared.open(walletKey: key, directory: dir)
        service.reset()
    }

    override func tearDown() async throws {
        LocalVault.shared.close(forget: true)
        BackupService.autoRunEnabled = true
        StorjImportService.autoRunEnabled = true
        service.parseWithAI = { text, filename in
            try await AmachAPIClient.shared.parseReportWithAI(text: text, sourceName: filename)
        }
        service.reset()
        try? FileManager.default.removeItem(at: dir)
    }

    private var vault: VaultDatabase { LocalVault.shared.database! }

    private func diagnostics(_ parsedBy: String, model: String? = nil, aiError: String? = nil) -> AmachAPIClient.ParseDiagnostics {
        AmachAPIClient.ParseDiagnostics(parsedBy: parsedBy, apiKeyPresent: true, aiServedBy: model,
                                        aiError: aiError, aiMs: 1000, totalMs: 1000)
    }

    func test_ai_result_waits_for_review_and_saves_only_on_confirm() async throws {
        service.parseWithAI = { [unowned self] _, _ in
            AmachAPIClient.AIParseOutcome(report: .bloodwork(MockPDFReports.mockBloodworkReport()),
                                          diagnostics: self.diagnostics("ai", model: "e2ee-deepseek-v4-flash"))
        }
        await service.read(pdfData: MockPDFReports.mockBloodworkPDF(), filename: "labs.pdf")

        guard case .review(let result) = service.state else { return XCTFail("expected review, got \(service.state)") }
        XCTAssertEqual(result.reader, .privateAI(model: "e2ee-deepseek-v4-flash"))
        XCTAssertEqual(try vault.labReportCount(), 0, "nothing saved before the user confirms")

        service.save(result)
        guard case .done(let done) = service.state else { return XCTFail("expected done, got \(service.state)") }
        XCTAssertFalse(done.wasDuplicate)
        XCTAssertEqual(try vault.labReportCount(), 1)
        let pdfs = try await vault.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lab_pdfs") }
        XCTAssertEqual(pdfs, 1, "the original PDF is kept for backup")
    }

    func test_an_ai_timeout_saves_nothing_and_says_why() async throws {
        service.parseWithAI = { _, _ in throw URLError(.timedOut) }
        await service.read(pdfData: MockPDFReports.mockBloodworkPDF(), filename: "labs.pdf")

        guard case .aiFailed(let message) = service.state else { return XCTFail("expected aiFailed, got \(service.state)") }
        XCTAssertTrue(message.contains("took too long"), message)
        XCTAssertTrue(message.contains("Nothing was saved"), message)
        XCTAssertEqual(try vault.labReportCount(), 0)
    }

    func test_enclave_busy_and_gateway_timeouts_have_plain_messages() {
        XCTAssertTrue(PDFUploadService.describe(APIError.enclaveBusy).contains("busy"))
        XCTAssertTrue(PDFUploadService.describe(APIError.httpError(statusCode: 504)).contains("took too long"))
    }

    func test_no_report_from_the_ai_is_a_failure_not_a_save() async throws {
        service.parseWithAI = { [unowned self] _, _ in
            AmachAPIClient.AIParseOutcome(report: nil, diagnostics: self.diagnostics("none", aiError: "enclave_busy: every model failed or timed out"))
        }
        await service.read(pdfData: MockPDFReports.mockBloodworkPDF(), filename: "labs.pdf")
        guard case .aiFailed(let message) = service.state else { return XCTFail("expected aiFailed") }
        XCTAssertTrue(message.contains("enclave_busy"), message)
        XCTAssertEqual(try vault.labReportCount(), 0)
    }

    func test_server_offline_parser_is_labelled_as_such() async throws {
        service.parseWithAI = { [unowned self] _, _ in
            AmachAPIClient.AIParseOutcome(report: .bloodwork(MockPDFReports.mockBloodworkReport()),
                                          diagnostics: self.diagnostics("local", aiError: "venice returned 401"))
        }
        await service.read(pdfData: MockPDFReports.mockBloodworkPDF(), filename: "labs.pdf")
        guard case .review(let result) = service.state else { return XCTFail("expected review") }
        XCTAssertEqual(result.reader, .serverParser(aiProblem: "venice returned 401"))
    }

    func test_offline_reader_is_opt_in_and_still_reviewed() async throws {
        service.parseWithAI = { _, _ in throw URLError(.timedOut) }
        await service.read(pdfData: MockPDFReports.mockBloodworkPDF(), filename: "labs.pdf")
        await service.readOffline(pdfData: MockPDFReports.mockBloodworkPDF(), filename: "labs.pdf")
        guard case .review(let result) = service.state else { return XCTFail("expected review, got \(service.state)") }
        XCTAssertEqual(result.reader, .phoneParser)
        XCTAssertEqual(try vault.labReportCount(), 0)
    }

    func test_parse_requests_use_the_long_session() {
        let config = AmachAPIClient.shared.parseSession.configuration
        XCTAssertGreaterThanOrEqual(config.timeoutIntervalForRequest, 300)
        XCTAssertGreaterThan(config.timeoutIntervalForResource, config.timeoutIntervalForRequest)
    }
}
