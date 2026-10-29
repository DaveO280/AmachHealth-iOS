// ReportParseGoldenTests.swift
// AmachHealth
//
// Opt-in comparison of the two report parse paths on real PDFs: the
// website's /api/health/parse-report (server) and DeviceReportParser (the
// same parser on the phone, model calls end to end encrypted through the
// relay). Skipped unless AMACH_PARSE_GOLDEN_DIR names a folder of PDFs
// outside the repo, since they're health data. Needs AMACH_API_URL (a relay
// with AMACH_E2EE_RELAY_ENABLED=true) and, without a wallet session,
// AMACH_E2EE_RELAY_TOKEN.
//
//   TEST_RUNNER_AMACH_PARSE_GOLDEN_DIR=<dir> TEST_RUNNER_AMACH_API_URL=<relay> \
//   TEST_RUNNER_AMACH_E2EE_RELAY_TOKEN=<token> [TEST_RUNNER_AMACH_PARSE_GOLDEN_RUNS=2] \
//   xcodebuild test ... -only-testing:"Amach HealthTests/ReportParseGoldenTests"
//
// Writes <dir>/out/<pdf>.<server|device>.<run>.json (the route's body) for
// scripts/compare-report-parses.py.

import XCTest
@testable import AmachHealth

final class ReportParseGoldenTests: XCTestCase {

    func test_server_and_device_parses_of_each_pdf() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dirPath = env["AMACH_PARSE_GOLDEN_DIR"], !dirPath.isEmpty else {
            throw XCTSkip("AMACH_PARSE_GOLDEN_DIR not set")
        }
        let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let runs = Int(env["AMACH_PARSE_GOLDEN_RUNS"] ?? "") ?? 1
        let only = env["AMACH_PARSE_GOLDEN_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let paths = env["AMACH_PARSE_GOLDEN_PATHS"].map { Set($0.split(separator: ",").map(String.init)) }
            ?? ["server", "device"]

        let pdfs = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(pdfs.isEmpty, "no PDFs in \(dirPath)")

        let device = DeviceReportParser(transport: E2EEReportParseTransport())
        for pdf in pdfs {
            let name = pdf.deletingPathExtension().lastPathComponent
            if let only, !only.contains(where: { name.localizedCaseInsensitiveContains($0) }) { continue }
            let text = PDFReportParser.extractText(from: try Data(contentsOf: pdf))
            for run in 1 ... runs {
                if paths.contains("server") {
                    let started = Date()
                    let body = try await serverParse(text: text, sourceName: pdf.lastPathComponent)
                    try body.write(to: out.appendingPathComponent("\(name).server.\(run).json"))
                    print("🧪 [Golden] \(name) server run \(run): \(Int(Date().timeIntervalSince(started)))s")
                }
                if paths.contains("device") {
                    let started = Date()
                    let body = try await device.parse(text: text, reportType: nil, sourceName: pdf.lastPathComponent)
                    try body.write(to: out.appendingPathComponent("\(name).device.\(run).json"))
                    print("🧪 [Golden] \(name) device run \(run): \(Int(Date().timeIntervalSince(started)))s")
                }
            }
        }
    }

    /// The route's raw body, whatever its status.
    private func serverParse(text: String, sourceName: String) async throws -> Data {
        var request = URLRequest(url: AmachAPIClient.shared.apiBaseURL.appendingPathComponent("api/health/parse-report"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "sourceName": sourceName])
        request.timeoutInterval = 600
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
