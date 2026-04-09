// PDFReportParserTests.swift
// AmachHealthTests
//
// Tests for:
//   - PDFReportParser: text extraction, bloodwork normalization, DEXA normalization
//   - FhirConverter: bloodwork ↔ FHIR round-trip, DEXA ↔ FHIR round-trip
//   - Fingerprinting: same data → same hash; different data → different hash
//   - PDF generation: PDFKit produces parseable output

import XCTest
@testable import AmachHealth

// MARK: - Report type detection

final class PDFReportTypeDetectionTests: XCTestCase {

    func test_detects_bloodwork_from_quest_text() {
        let text = MockPDFReports.mockBloodworkPDFText()
        let report = PDFReportParser.parseText(text, filename: "bloodwork.pdf")
        XCTAssertNotNil(report, "Should detect a report")
        if case .bloodwork = report { /* pass */ } else {
            XCTFail("Expected bloodwork, got \(String(describing: report))")
        }
    }

    func test_detects_dexa_from_hologic_text() {
        let text = MockPDFReports.mockDexaPDFText()
        let report = PDFReportParser.parseText(text, filename: "dexa_scan.pdf")
        XCTAssertNotNil(report, "Should detect a report")
        if case .dexa = report { /* pass */ } else {
            XCTFail("Expected DEXA, got \(String(describing: report))")
        }
    }

    func test_returns_nil_for_empty_text() {
        XCTAssertNil(PDFReportParser.parseText("", filename: "empty.pdf"))
    }

    func test_returns_nil_for_nonsense_text() {
        XCTAssertNil(PDFReportParser.parseText("Hello world this is not a lab report.", filename: "note.pdf"))
    }

    func test_dexa_filename_hint_not_required() {
        // DEXA keywords in body are sufficient
        let text = MockPDFReports.mockDexaPDFText()
        let report = PDFReportParser.parseText(text, filename: "report.pdf")
        XCTAssertNotNil(report)
    }
}

// MARK: - Bloodwork parsing

final class BloodworkParserTests: XCTestCase {

    private var parsed: BloodworkReportData!

    override func setUp() {
        super.setUp()
        let text = MockPDFReports.mockBloodworkPDFText()
        parsed = PDFReportParser.parseBloodworkText(text)
    }

    func test_extracts_glucose() {
        let metric = parsed.metrics.first { $0.name.lowercased() == "glucose" }
        XCTAssertNotNil(metric, "Glucose should be extracted")
        XCTAssertEqual(metric?.value, 94)
        XCTAssertEqual(metric?.unit, "mg/dL")
        XCTAssertEqual(metric?.referenceRange, "65-99")
    }

    func test_extracts_hba1c() {
        let metric = parsed.metrics.first { $0.name.lowercased() == "hba1c" }
        XCTAssertNotNil(metric)
        XCTAssertEqual(metric?.value, 5.2, accuracy: 0.01)
        XCTAssertEqual(metric?.unit, "%")
    }

    func test_extracts_lipid_panel() {
        let names = parsed.metrics.map { $0.name.lowercased() }
        XCTAssertTrue(names.contains(where: { $0.contains("cholesterol") }), "Should extract cholesterol")
        XCTAssertTrue(names.contains(where: { $0.contains("triglyceride") }), "Should extract triglycerides")
    }

    func test_extracts_tsh() {
        let metric = parsed.metrics.first { $0.name.lowercased() == "tsh" }
        XCTAssertNotNil(metric)
        XCTAssertEqual(metric?.value, 1.82, accuracy: 0.001)
        XCTAssertEqual(metric?.unit, "mIU/L")
    }

    func test_extracts_vitamin_d() {
        let metric = parsed.metrics.first { $0.name.lowercased().contains("vitamin d") }
        XCTAssertNotNil(metric)
        XCTAssertEqual(metric?.value, 42)
    }

    func test_extracts_ferritin() {
        let metric = parsed.metrics.first { $0.name.lowercased() == "ferritin" }
        XCTAssertNotNil(metric)
        XCTAssertEqual(metric?.value, 85)
    }

    func test_detects_laboratory() {
        XCTAssertEqual(parsed.laboratory, "Quest Diagnostics")
    }

    func test_detects_report_date() {
        // Date "11/14/2025" should normalize to "2025-11-14"
        XCTAssertEqual(parsed.reportDate, "2025-11-14")
    }

    func test_confidence_above_threshold() {
        XCTAssertGreaterThan(parsed.confidence, 0.5, "Confidence should be > 0.5 for a full panel")
    }

    func test_metrics_are_deduplicated() {
        let names = parsed.metrics.map { $0.name.lowercased() }
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count, "No duplicate metric names")
    }

    func test_report_type_is_bloodwork() {
        XCTAssertEqual(parsed.type, "bloodwork")
    }

    func test_panels_populated() {
        XCTAssertFalse(parsed.panels.isEmpty, "Panels dict should have entries")
    }
}

// MARK: - DEXA parsing

final class DexaParserTests: XCTestCase {

    private var parsed: DexaReportData!

    override func setUp() {
        super.setUp()
        let text = MockPDFReports.mockDexaPDFText()
        parsed = PDFReportParser.parseDexaText(text)
    }

    func test_detects_type() {
        XCTAssertEqual(parsed.type, "dexa")
    }

    func test_extracts_body_fat_percent() {
        XCTAssertEqual(parsed.totalBodyFatPercent, 18.4, accuracy: 0.1)
    }

    func test_extracts_lean_mass() {
        XCTAssertEqual(parsed.totalLeanMassKg ?? 0, 67.2, accuracy: 0.1)
    }

    func test_extracts_scan_date() {
        // "09/22/2025" → "2025-09-22"
        XCTAssertEqual(parsed.scanDate, "2025-09-22")
    }

    func test_extracts_bmd() {
        XCTAssertNotNil(parsed.boneDensityTotal, "Bone density total should be extracted")
        XCTAssertEqual(parsed.boneDensityTotal?.bmd, 1.28, accuracy: 0.01)
    }

    func test_extracts_t_score() {
        XCTAssertEqual(parsed.boneDensityTotal?.tScore, 0.6, accuracy: 0.1)
    }

    func test_extracts_z_score() {
        XCTAssertEqual(parsed.boneDensityTotal?.zScore, 0.8, accuracy: 0.1)
    }

    func test_extracts_visceral_fat_rating() {
        XCTAssertEqual(parsed.visceralFatRating, 1.2, accuracy: 0.1)
    }

    func test_extracts_visceral_fat_area() {
        XCTAssertEqual(parsed.visceralFatAreaCm2 ?? 0, 42.8, accuracy: 0.1)
    }

    func test_extracts_android_gynoid_ratio() {
        XCTAssertEqual(parsed.androidGynoidRatio, 0.84, accuracy: 0.01)
    }

    func test_detects_source_hologic() {
        XCTAssertEqual(parsed.source, "Hologic")
    }

    func test_confidence_above_threshold() {
        XCTAssertGreaterThan(parsed.confidence, 0.3)
    }
}

// MARK: - FHIR round-trip: Bloodwork

final class BloodworkFhirRoundTripTests: XCTestCase {

    func test_convert_to_fhir_and_back() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        let decoded = FhirConverter.convertFhirToBloodwork(fhir, rawText: "raw", source: original.source)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, "bloodwork")
        XCTAssertEqual(decoded?.metrics.count, original.metrics.count,
                       "Round-trip should preserve metric count")
    }

    func test_fhir_resource_type() {
        let report = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        XCTAssertEqual(fhir.resourceType, "DiagnosticReport")
        XCTAssertEqual(fhir.status, "final")
    }

    func test_fhir_observations_match_metrics() {
        let report = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        XCTAssertEqual(fhir.contained?.count, report.metrics.count,
                       "One observation per metric")
    }

    func test_glucose_observation_value_preserved() {
        let report = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        let glucoseObs = fhir.contained?.first {
            $0.code.coding.first?.display?.lowercased() == "glucose"
        }
        XCTAssertNotNil(glucoseObs, "Glucose observation should exist")
        XCTAssertEqual(glucoseObs?.valueQuantity?.value, 94)
        XCTAssertEqual(glucoseObs?.valueQuantity?.unit, "mg/dL")
    }

    func test_flag_encoded_as_interpretation() {
        let metric = BloodworkMetric(name: "LDL", value: 145, valueText: "145", unit: "mg/dL",
                                    referenceRange: "< 100", panel: "Lipid", collectedAt: nil,
                                    flag: "high", interpretationNotes: nil)
        let report = BloodworkReportData(type: "bloodwork", source: nil, reportDate: nil,
                                         laboratory: nil, panels: [:], metrics: [metric],
                                         notes: nil, rawText: "", confidence: 0.9)
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        let obs = fhir.contained?.first
        let interpCode = obs?.interpretation?.first?.coding.first?.code
        XCTAssertEqual(interpCode, "H", "High flag should encode as 'H'")
    }

    func test_reference_range_preserved() {
        let report = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        let glucoseObs = fhir.contained?.first {
            $0.code.coding.first?.display?.lowercased() == "glucose"
        }
        XCTAssertEqual(glucoseObs?.referenceRange?.first?.text, "65-99")
    }

    func test_fhir_conclusion_includes_laboratory() {
        let report = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        XCTAssertTrue(fhir.conclusion?.contains("Quest Diagnostics") ?? false,
                      "Conclusion should mention the laboratory")
    }

    func test_round_trip_preserves_metric_names() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        let originalNames = Set(original.metrics.map { $0.name })
        let decodedNames = Set(decoded.metrics.map { $0.name })
        XCTAssertEqual(originalNames, decodedNames, "Metric names should survive round-trip")
    }
}

// MARK: - FHIR round-trip: DEXA

final class DexaFhirRoundTripTests: XCTestCase {

    func test_fhir_resource_type() {
        let report = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(report)
        XCTAssertEqual(fhir.resourceType, "DiagnosticReport")
        XCTAssertEqual(fhir.status, "final")
    }

    func test_fhir_code_is_dxa() {
        let report = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(report)
        let code = fhir.code.coding.first?.code
        XCTAssertEqual(code, "38269-7", "DEXA should use LOINC 38269-7")
    }

    func test_total_fat_observation_value_preserved() {
        let report = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(report)
        let fatObs = fhir.contained?.first { $0.code.coding.first?.code == "41982-7" && $0.component == nil }
        XCTAssertNotNil(fatObs, "Total body fat observation should exist")
        XCTAssertEqual(fatObs?.valueQuantity?.value, 18.4, accuracy: 0.01)
    }

    func test_round_trip_preserves_fat_percent() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.totalBodyFatPercent, original.totalBodyFatPercent,
                       accuracy: 0.01)
    }

    func test_round_trip_preserves_lean_mass() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.totalLeanMassKg, original.totalLeanMassKg,
                       accuracy: 0.01)
    }

    func test_round_trip_preserves_android_gynoid() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.androidGynoidRatio, original.androidGynoidRatio,
                       accuracy: 0.001)
    }

    func test_round_trip_preserves_region_count() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.regions.count, original.regions.count,
                       "Region count should survive round-trip")
    }

    func test_round_trip_preserves_bone_density() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.boneDensityTotal?.bmd, original.boneDensityTotal?.bmd,
                       accuracy: 0.001)
        XCTAssertEqual(decoded?.boneDensityTotal?.tScore, original.boneDensityTotal?.tScore,
                       accuracy: 0.001)
    }

    func test_conclusion_mentions_source() {
        let report = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(report)
        XCTAssertTrue(fhir.conclusion?.contains("Hologic") ?? false,
                      "Conclusion should mention source")
    }
}

// MARK: - Fingerprinting

final class FingerprintTests: XCTestCase {

    func test_bloodwork_fingerprint_is_stable() {
        let report = MockPDFReports.mockBloodworkReport()
        let fp1 = FhirConverter.fingerprintBloodwork(report)
        let fp2 = FhirConverter.fingerprintBloodwork(report)
        XCTAssertEqual(fp1, fp2, "Fingerprint must be deterministic")
        XCTAssertFalse(fp1.isEmpty)
    }

    func test_dexa_fingerprint_is_stable() {
        let report = MockPDFReports.mockDexaReport()
        let fp1 = FhirConverter.fingerprintDexa(report)
        let fp2 = FhirConverter.fingerprintDexa(report)
        XCTAssertEqual(fp1, fp2)
    }

    func test_different_bloodwork_reports_have_different_fingerprints() {
        let r1 = MockPDFReports.mockBloodworkReport()
        let r2 = BloodworkReportData(
            type: "bloodwork", source: r1.source, reportDate: r1.reportDate,
            laboratory: r1.laboratory, panels: r1.panels,
            metrics: r1.metrics.map {
                BloodworkMetric(name: $0.name, value: ($0.value ?? 0) + 1,
                               valueText: $0.valueText, unit: $0.unit,
                               referenceRange: $0.referenceRange, panel: $0.panel,
                               collectedAt: $0.collectedAt, flag: $0.flag,
                               interpretationNotes: $0.interpretationNotes)
            },
            notes: r1.notes, rawText: r1.rawText, confidence: r1.confidence
        )
        XCTAssertNotEqual(
            FhirConverter.fingerprintBloodwork(r1),
            FhirConverter.fingerprintBloodwork(r2),
            "Different values must produce different fingerprints"
        )
    }

    func test_different_dexa_reports_have_different_fingerprints() {
        let r1 = MockPDFReports.mockDexaReport()
        let r2 = DexaReportData(
            type: r1.type, source: r1.source, scanDate: r1.scanDate,
            totalBodyFatPercent: (r1.totalBodyFatPercent ?? 0) + 1.0,
            totalLeanMassKg: r1.totalLeanMassKg,
            visceralFatRating: r1.visceralFatRating,
            visceralFatAreaCm2: r1.visceralFatAreaCm2,
            visceralFatVolumeCm3: r1.visceralFatVolumeCm3,
            boneDensityTotal: r1.boneDensityTotal,
            androidGynoidRatio: r1.androidGynoidRatio,
            regions: r1.regions, notes: r1.notes,
            rawText: r1.rawText, confidence: r1.confidence
        )
        XCTAssertNotEqual(
            FhirConverter.fingerprintDexa(r1),
            FhirConverter.fingerprintDexa(r2)
        )
    }

    func test_fingerprint_length_is_sha256_hex() {
        let fp = FhirConverter.fingerprintBloodwork(MockPDFReports.mockBloodworkReport())
        XCTAssertEqual(fp.count, 64, "SHA-256 hex should be 64 chars")
        XCTAssertTrue(fp.allSatisfy { $0.isHexDigit }, "Fingerprint should be hex")
    }
}

// MARK: - PDF generation + parse

final class PDFGenerationAndParseTests: XCTestCase {

    func test_generated_bloodwork_pdf_is_parseable() {
        let pdfData = MockPDFReports.mockBloodworkPDF()
        XCTAssertFalse(pdfData.isEmpty, "Generated PDF should not be empty")
        let report = PDFReportParser.parse(pdfData: pdfData, filename: "bloodwork.pdf")
        XCTAssertNotNil(report, "Should parse generated bloodwork PDF")
        if case .bloodwork(let bw) = report {
            XCTAssertFalse(bw.metrics.isEmpty, "Should extract at least one metric")
        } else {
            XCTFail("Expected bloodwork report")
        }
    }

    func test_generated_dexa_pdf_is_parseable() {
        let pdfData = MockPDFReports.mockDexaPDF()
        XCTAssertFalse(pdfData.isEmpty)
        let report = PDFReportParser.parse(pdfData: pdfData, filename: "dexa.pdf")
        XCTAssertNotNil(report, "Should parse generated DEXA PDF")
        if case .dexa(let dexa) = report {
            XCTAssertNotNil(dexa.totalBodyFatPercent, "Should extract body fat %")
        } else {
            XCTFail("Expected DEXA report")
        }
    }
}

// MARK: - FHIR JSON serialisation (cross-platform compatibility)

final class FhirJsonSerializationTests: XCTestCase {

    func test_bloodwork_fhir_serializes_to_valid_json() throws {
        let report = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(fhir)
        XCTAssertFalse(data.isEmpty)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["resourceType"] as? String, "DiagnosticReport")
        XCTAssertEqual(json["status"] as? String, "final")
    }

    func test_dexa_fhir_serializes_to_valid_json() throws {
        let report = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(report)
        let encoder = JSONEncoder()
        let data = try encoder.encode(fhir)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["resourceType"] as? String, "DiagnosticReport")
    }

    func test_fhir_json_is_website_compatible() throws {
        let report = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(fhir)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Keys that the website's convertFhirToBloodwork() expects:
        XCTAssertNotNil(json["contained"],   "contained array required by website decoder")
        XCTAssertNotNil(json["result"],      "result references required by website decoder")
        XCTAssertNotNil(json["effectiveDateTime"] as? String, "effectiveDateTime required")
    }
}
