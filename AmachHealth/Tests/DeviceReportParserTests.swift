// DeviceReportParserTests.swift
// AmachHealth
//
// The website's parser bundle running in JavaScriptCore, with a fake model
// transport: the host's promises, timers and parallel calls work, and its
// failures map to the route's codes. Synthetic report only.

import XCTest
@testable import AmachHealth

final class DeviceReportParserTests: XCTestCase {

    /// A synthetic cumulative lab report, as in the website's
    /// deviceBundle.test.ts.
    private func labReport(panels: Int, testsPerPanel: Int) -> String {
        var lines = ["Example Patient", "DOB: 01/01/1980 Age: 46", "Collected Date 05/21/2026 12:56",
                     "Reported 05/26/2026 12:55", "Ulta Lab Tests, LLC", ""]
        for p in 0 ..< panels {
            lines.append("PANEL \(Character(UnicodeScalar(65 + p)!))")
            for t in 0 ..< testsPerPanel {
                lines.append("TEST \(p)-\(t)   \(50 + t)   \(40 + t)-\(90 + t) mg/dL   05/21/2026   \(48 + t)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Reads the rows it was given back as metrics.
    private final class FakeModel: ReportParseTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [ReportParseCall] = []
        var failure: Error?

        func complete(_ call: ReportParseCall) async throws -> ReportParseReply {
            lock.lock(); calls.append(call); lock.unlock()
            // Let the parallel section calls overlap.
            try await Task.sleep(nanoseconds: 20_000_000)
            if let failure { throw failure }
            let user = call.messages.last { $0.role == "user" }!.content
            let regex = try NSRegularExpression(pattern: #"TEST (\d+-\d+)\s+(\d+)\s+(\d+-\d+) mg/dL"#)
            let ns = user as NSString
            let metrics: [[String: Any]] = regex.matches(in: user, range: NSRange(location: 0, length: ns.length)).map {
                ["name": "Test " + ns.substring(with: $0.range(at: 1)),
                 "value": Int(ns.substring(with: $0.range(at: 2)))!,
                 "unit": "mg/dL",
                 "referenceRange": ns.substring(with: $0.range(at: 3))]
            }
            let data = try JSONSerialization.data(withJSONObject: ["reportDate": "2026-05-21", "metrics": metrics])
            return ReportParseReply(content: String(decoding: data, as: UTF8.self), model: "e2ee-test")
        }
    }

    private func parse(_ parser: DeviceReportParser, _ text: String) async throws -> [String: Any] {
        let data = try await parser.parse(text: text, reportType: "bloodwork", sourceName: "lab.pdf")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_bundle_matches_its_hash() {
        XCTAssertEqual(DeviceReportParser.sha256Hex(ReportParserBundle.source), ReportParserBundle.sha256)
    }

    func test_parses_a_sectioned_report_with_parallel_encrypted_calls() async throws {
        let model = FakeModel()
        let parser = DeviceReportParser(transport: model)
        let body = try await parse(parser, labReport(panels: 9, testsPerPanel: 12))

        XCTAssertEqual(body["success"] as? Bool, true)
        let reports = try XCTUnwrap(body["reports"] as? [[String: Any]])
        let report = try XCTUnwrap(reports.first?["report"] as? [String: Any])
        XCTAssertEqual(report["type"] as? String, "bloodwork")
        let metrics = try XCTUnwrap(report["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.count, 9 * 12)
        XCTAssertGreaterThan(model.calls.count, 1, "long reports go out in sections")
        let diagnostics = try XCTUnwrap(body["diagnostics"] as? [String: Any])
        XCTAssertEqual(diagnostics["aiServedBy"] as? String, "e2ee-test")
        XCTAssertTrue(model.calls.allSatisfy { $0.tier == .parseText && $0.messages.filter { $0.role == "system" }.count == 1 })
    }

    func test_tiers_tell_lab_reports_from_gut_reports_without_a_model_call() async throws {
        let model = FakeModel()
        let parser = DeviceReportParser(transport: model)
        let lab = try await parser.tiers(text: labReport(panels: 2, testsPerPanel: 6), reportType: "bloodwork")
        XCTAssertEqual(lab, ["parseText"])
        XCTAssertTrue(lab.isDisjoint(with: PrivateReportParsing.serverOnlyTiers))
        let gut = try await parser.tiers(text: "x", reportType: "gut-health")
        XCTAssertFalse(gut.isDisjoint(with: PrivateReportParsing.serverOnlyTiers))
        XCTAssertTrue(model.calls.isEmpty)
    }

    func test_the_same_context_parses_again() async throws {
        let parser = DeviceReportParser(transport: FakeModel())
        for _ in 0 ..< 2 {
            let body = try await parse(parser, labReport(panels: 2, testsPerPanel: 6))
            XCTAssertEqual(body["success"] as? Bool, true)
        }
    }

    func test_busy_and_credit_map_to_the_route_codes() async throws {
        let model = FakeModel()
        let parser = DeviceReportParser(transport: model)
        model.failure = APIError.enclaveBusy
        var body = try await parse(parser, labReport(panels: 2, testsPerPanel: 6))
        XCTAssertEqual(body["code"] as? String, "enclave_busy")

        model.failure = APIError.aiCreditExhausted(resetsAt: Date(timeIntervalSince1970: 1_800_000_000))
        body = try await parse(parser, labReport(panels: 2, testsPerPanel: 6))
        XCTAssertEqual(body["code"] as? String, "ai_credit_exhausted")
        XCTAssertNotNil(body["resetsAt"] as? String)
    }

    func test_an_encryption_failure_is_an_error_not_the_regex_fallback() async throws {
        let model = FakeModel()
        model.failure = APIError.requestFailed("Luma's private connection couldn't be verified. Please try again.")
        let body = try await parse(DeviceReportParser(transport: model), labReport(panels: 2, testsPerPanel: 6))
        XCTAssertEqual(body["success"] as? Bool, false)
        XCTAssertEqual(body["code"] as? String, "e2ee_failed")
        XCTAssertNil(body["reports"])
    }

    func test_a_tampered_bundle_is_refused() async {
        let parser = DeviceReportParser(transport: FakeModel(), source: ReportParserBundle.source + "\n//x",
                                        sha256: ReportParserBundle.sha256)
        do {
            _ = try await parser.parse(text: "x", reportType: nil, sourceName: nil)
            XCTFail("expected bundleTampered")
        } catch {
            XCTAssertEqual(error as? DeviceReportParser.HostError, .bundleTampered)
        }
    }

    func test_limiter_caps_calls_in_flight() async {
        let limiter = AsyncLimiter(limit: 3)
        actor Peak { var now = 0, max = 0
            func enter() { now += 1; max = Swift.max(max, now) }
            func leave() { now -= 1 } }
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    await limiter.acquire()
                    await peak.enter()
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    await peak.leave()
                    await limiter.release()
                }
            }
        }
        let max = await peak.max
        XCTAssertEqual(max, 3)
    }

    func test_error_json_carries_codes_not_contents() throws {
        let json = DeviceReportParser.errorJSON(APIError.enclaveBusy)
        XCTAssertEqual(json, #"{"code":"enclave_busy"}"#)
    }
}
