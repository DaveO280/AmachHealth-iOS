// LivePDFImportTests.swift
// AmachHealthTests
//
// Opt-in: runs real PDFs through the phone's import flow (PDFKit extraction,
// the long parse session, PDFUploadService.read) against a deployed website.
// Skipped unless these are set (xcodebuild passes TEST_RUNNER_-prefixed
// variables through to the test process):
//
//   TEST_RUNNER_AMACH_API_URL=https://<deployment>.vercel.app
//   TEST_RUNNER_AMACH_LIVE_PDF=/path/to/report.pdf
//   TEST_RUNNER_AMACH_VERCEL_SHARE_URL=<Vercel share link>  (protected previews)
//
// Prints a one-line summary with the reader, time and value count; never the
// report's contents. Nothing is saved.

import XCTest
@testable import AmachHealth

@MainActor
final class LivePDFImportTests: XCTestCase {

    func test_live_pdf_is_read_by_the_private_ai() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AMACH_API_URL"] != nil, let path = env["AMACH_LIVE_PDF"] else {
            throw XCTSkip("Set AMACH_API_URL and AMACH_LIVE_PDF to run")
        }
        if let share = env["AMACH_VERCEL_SHARE_URL"].flatMap(URL.init(string:)) {
            // The share link sets Vercel's access cookie in the shared cookie store.
            let (_, response) = try await AmachAPIClient.shared.parseSession.data(from: share)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "share link rejected")
        }

        let service = PDFUploadService.shared
        service.reset()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let started = Date()
        await service.read(pdfData: data, filename: URL(fileURLWithPath: path).lastPathComponent)
        let seconds = Date().timeIntervalSince(started)

        switch service.state {
        case .review(let result):
            var count = 0
            switch result.report {
            case .bloodwork(let bw): count = bw.metrics.count
            case .dexa(let dx): count = dx.regions.count
            case .medicalRecord(let mr): count = mr.keyFindings?.count ?? 0
            case .gutHealth(let gut): count = LabVaultMapping.gutHealthMarkers(gut.json, reportId: "live").count
            }
            print("LIVE_PDF_IMPORT reader=\(result.reader) type=\(result.report.reportType) values=\(count) seconds=\(Int(seconds))")
            XCTAssertTrue(result.reader.isAI, "expected the private AI to read it, got \(result.reader)")
            XCTAssertGreaterThan(count, 0)
        case .aiFailed(let message):
            XCTFail("AI failed after \(Int(seconds)) s: \(message)")
        default:
            XCTFail("unexpected state after \(Int(seconds)) s: \(service.state)")
        }
        service.reset()
    }
}
