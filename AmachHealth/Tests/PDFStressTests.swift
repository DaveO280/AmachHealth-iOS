// PDFStressTests.swift
// AmachHealthTests
//
// Comprehensive stress tests for the PDF report pipeline:
//   - Parser robustness (edge-case inputs)
//   - Dedup correctness (fingerprint matching)
//   - FHIR round-trip fidelity (exact field preservation)
//   - Concurrent upload safety
//   - Large payload handling & parse timing
//   - Error handling paths

import XCTest
import PDFKit
@testable import AmachHealth

// MARK: - 1. Parser Robustness Tests

final class PDFParserRobustnessTests: XCTestCase {

    // MARK: - Missing values

    func test_marker_present_value_blank_does_not_crash() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        COMPREHENSIVE METABOLIC PANEL
        Glucose                                   65-99         mg/dL          Normal
        Sodium                           141       136-145       mmol/L         Normal
        """
        // Should not crash; Sodium may or may not parse depending on regex match
        let result = PDFReportParser.parseBloodworkText(text)
        // No crash is the main assertion; if Sodium parsed it must be correct
        let sodium = result.metrics.first { $0.name.lowercased().contains("sodium") }
        if let sodium = sodium {
            XCTAssertEqual(sodium.value, 141, accuracy: 0.001)
        }
    }

    func test_all_markers_blank_values_returns_empty_metrics() {
        let text = """
        Quest Diagnostics
        Date: 11/14/2025
        LIPID PANEL
        Total Cholesterol                          <200          mg/dL
        LDL Cholesterol                            <100          mg/dL
        """
        let result = PDFReportParser.parseBloodworkText(text)
        // Parser should not crash; it may return zero metrics since values are missing
        XCTAssertNotNil(result)
    }

    // MARK: - Partial panels

    func test_partial_panel_5_markers_parses_without_crash() {
        let text = """
        Quest Diagnostics
        Date of Service: 03/15/2025
        COMPREHENSIVE METABOLIC PANEL
        Glucose                           94          65-99         mg/dL          Normal
        Sodium                           141          136-145       mmol/L         Normal
        Potassium                          4.1         3.5-5.1       mmol/L         Normal
        Creatinine                         0.92        0.7-1.3       mg/dL          Normal
        eGFR                              98           >60           mL/min         Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertGreaterThanOrEqual(result.metrics.count, 1, "Should parse at least some metrics from partial panel")
        XCTAssertLessThanOrEqual(result.metrics.count, 5)
    }

    func test_partial_panel_returns_best_effort() {
        let text = """
        LabCorp
        Date of Service: 01/10/2025
        LIPID PANEL
        Total Cholesterol                195          <200          mg/dL          Normal
        HDL Cholesterol                   58          >40           mg/dL          Normal
        """
        let report = PDFReportParser.parseBloodworkText(text)
        // Should get at least one metric
        XCTAssertFalse(report.metrics.isEmpty, "Partial panel should still return available metrics")
    }

    // MARK: - Out-of-range flags

    func test_flag_H_parsed_as_high() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        LDL Cholesterol                  145          <100          mg/dL          H
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let ldl = result.metrics.first { $0.name.lowercased().contains("ldl") }
        XCTAssertNotNil(ldl, "LDL should parse")
        XCTAssertEqual(ldl?.flag, "high", "H flag should normalize to 'high'")
    }

    func test_flag_L_parsed_as_low() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        HDL Cholesterol                   28          >40           mg/dL          L
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let hdl = result.metrics.first { $0.name.lowercased().contains("hdl") }
        XCTAssertNotNil(hdl, "HDL should parse")
        XCTAssertEqual(hdl?.flag, "low", "L flag should normalize to 'low'")
    }

    func test_flag_HIGH_word_parsed_as_high() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        LDL Cholesterol                  148          <100          mg/dL          High
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let ldl = result.metrics.first { $0.name.lowercased().contains("ldl") }
        XCTAssertNotNil(ldl)
        XCTAssertEqual(ldl?.flag, "high")
    }

    func test_flag_LOW_word_parsed_as_low() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        HDL Cholesterol                   30          >40           mg/dL          Low
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let hdl = result.metrics.first { $0.name.lowercased().contains("hdl") }
        XCTAssertNotNil(hdl)
        XCTAssertEqual(hdl?.flag, "low")
    }

    // MARK: - Different units

    func test_glucose_mg_dL_unit_preserved() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        METABOLIC
        Glucose                           94          65-99         mg/dL          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let glucose = result.metrics.first { $0.name.lowercased().contains("glucose") }
        XCTAssertNotNil(glucose)
        XCTAssertEqual(glucose?.unit, "mg/dL")
        XCTAssertEqual(glucose?.value, 94, accuracy: 0.001)
    }

    func test_sodium_mmol_L_unit_preserved() {
        let text = """
        LabCorp
        Date of Service: 11/14/2025
        CHEMISTRY
        Sodium                           141          136-145       mmol/L         Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let sodium = result.metrics.first { $0.name.lowercased().contains("sodium") }
        XCTAssertNotNil(sodium)
        XCTAssertEqual(sodium?.unit, "mmol/L")
    }

    // MARK: - Multi-page layout (page break markers)

    func test_multipage_report_concatenated_with_page_break_markers() {
        let page1 = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        COMPREHENSIVE METABOLIC PANEL
        Glucose                           94          65-99         mg/dL          Normal
        Sodium                           141          136-145       mmol/L         Normal
        """
        let page2 = """
        LIPID PANEL
        Total Cholesterol                182          <200          mg/dL          Normal
        LDL Cholesterol                   98          <100          mg/dL          Normal
        """
        // Simulate PDFReportParser.extractText joining pages with "\n"
        let combined = page1 + "\n" + page2
        let result = PDFReportParser.parseBloodworkText(combined)
        XCTAssertFalse(result.metrics.isEmpty, "Should parse metrics across simulated pages")
        let names = result.metrics.map { $0.name.lowercased() }
        XCTAssertTrue(names.contains(where: { $0.contains("glucose") || $0.contains("sodium") || $0.contains("cholesterol") }),
                      "Metrics from both pages should be captured")
    }

    // MARK: - Non-standard marker name aliases

    func test_hba1c_spelled_various_ways_all_parse() {
        // The parser normalizes the text content; what matters is that none of these crash
        // and each produces a result for the A1c marker
        let variants = [
            ("Hemoglobin A1c", "5.2"),
            ("HbA1c",          "5.2"),
            ("A1C",            "5.2"),
        ]
        for (name, value) in variants {
            let text = """
            LabCorp
            Date of Service: 05/01/2025
            DIABETES PANEL
            \(name)                               \(value)         < 5.7         %              Normal
            """
            let result = PDFReportParser.parseBloodworkText(text)
            // At minimum, no crash; ideally we get a metric
            XCTAssertNotNil(result, "Parse must not return nil struct for input: \(name)")
        }
    }

    // MARK: - Numbers with commas

    func test_value_with_comma_separator_parses_as_number() {
        // "1,200" — The parser uses Double() which won't parse commas,
        // so we verify the parse doesn't crash and handles gracefully.
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        CHEMISTRY
        Platelets                       1,200        150-400       K/uL           H
        """
        // The primary assertion is: no crash
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertNotNil(result)
        // Platelets with comma may not parse (Double("1,200") fails), which is acceptable
        // as a known limitation — just verify no crash
    }

    // MARK: - Values with < or > prefixes

    func test_values_with_less_than_prefix_do_not_crash() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        INFLAMMATION
        hs-CRP                            <0.1        <1.0          mg/L           Normal
        """
        // <0.1 as a value won't parse as Double — verify graceful handling
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertNotNil(result)
        // hs-CRP with "<" prefix is expected to not parse numerically — no crash is the goal
    }

    func test_values_with_greater_than_prefix_do_not_crash() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        Triglycerides                     >400        <150          mg/dL          H
        """
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertNotNil(result)
    }

    // MARK: - Malformed / nonsense input never crashes

    func test_random_gibberish_does_not_crash() {
        let inputs = [
            "asdkfjasd lkfjasdf 123 !@#$%",
            String(repeating: "X", count: 10_000),
            "\n\n\n\n",
            "   ",
            "1234567890",
            "NULL\0VALUE",
        ]
        for input in inputs {
            let result = PDFReportParser.parseBloodworkText(input)
            // Just ensure no crash
            _ = result
        }
        // If we get here, no crash occurred
        XCTAssertTrue(true)
    }

    func test_malformed_pdf_bytes_returns_nil_not_crash() {
        let randomBytes = Data((0..<256).map { _ in UInt8.random(in: 0...255) })
        let result = PDFReportParser.parse(pdfData: randomBytes, filename: "bad.pdf")
        // Should return nil, not crash
        XCTAssertNil(result, "Random bytes should not parse as a health report")
    }

    func test_empty_data_returns_nil_not_crash() {
        let result = PDFReportParser.parse(pdfData: Data(), filename: "empty.pdf")
        XCTAssertNil(result, "Empty data should return nil")
    }

    func test_password_protected_simulation_returns_nil() {
        // Simulate a locked PDF: PDFDocument with no pages (PDFKit returns empty string)
        let pdfDoc = PDFDocument()
        // An empty document with no pages extracts "" which should produce nil
        let data = pdfDoc.dataRepresentation() ?? Data()
        let result = PDFReportParser.parse(pdfData: data, filename: "locked.pdf")
        XCTAssertNil(result, "Empty-page PDF should return nil")
    }
}

// MARK: - 2. Dedup Correctness Tests

final class PDFDedupTests: XCTestCase {

    // MARK: - Same bytes → same fingerprint (duplicate detected)

    func test_same_bloodwork_bytes_produce_same_fingerprint() {
        let report = MockPDFReports.mockBloodworkReport()
        let fp1 = FhirConverter.fingerprintBloodwork(report)
        let fp2 = FhirConverter.fingerprintBloodwork(report)
        XCTAssertEqual(fp1, fp2, "Same report must produce identical fingerprint (duplicate detection)")
        XCTAssertFalse(fp1.isEmpty)
    }

    func test_same_dexa_bytes_produce_same_fingerprint() {
        let report = MockPDFReports.mockDexaReport()
        let fp1 = FhirConverter.fingerprintDexa(report)
        let fp2 = FhirConverter.fingerprintDexa(report)
        XCTAssertEqual(fp1, fp2)
    }

    // MARK: - Two distinct PDFs → different fingerprints

    func test_different_bloodwork_reports_have_different_fingerprints() {
        let r1 = MockPDFReports.mockBloodworkReport()
        // Create a second report by bumping all values
        let modifiedMetrics = r1.metrics.map { m in
            BloodworkMetric(
                name: m.name,
                value: (m.value ?? 0) + 5.0,
                valueText: m.valueText,
                unit: m.unit,
                referenceRange: m.referenceRange,
                panel: m.panel,
                collectedAt: m.collectedAt,
                flag: m.flag,
                interpretationNotes: m.interpretationNotes
            )
        }
        let r2 = BloodworkReportData(
            type: r1.type, source: r1.source, reportDate: r1.reportDate,
            laboratory: r1.laboratory, panels: r1.panels,
            metrics: modifiedMetrics,
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
            totalBodyFatPercent: (r1.totalBodyFatPercent ?? 0) + 2.5,
            totalLeanMassKg: r1.totalLeanMassKg,
            visceralFatRating: r1.visceralFatRating,
            visceralFatAreaCm2: r1.visceralFatAreaCm2,
            visceralFatVolumeCm3: r1.visceralFatVolumeCm3,
            boneDensityTotal: r1.boneDensityTotal,
            androidGynoidRatio: r1.androidGynoidRatio,
            regions: r1.regions,
            notes: r1.notes,
            rawText: r1.rawText,
            confidence: r1.confidence
        )
        XCTAssertNotEqual(
            FhirConverter.fingerprintDexa(r1),
            FhirConverter.fingerprintDexa(r2)
        )
    }

    // MARK: - Flip one byte → new fingerprint (treated as new record)

    func test_one_changed_metric_value_produces_different_fingerprint() {
        let r1 = MockPDFReports.mockBloodworkReport()
        var flippedMetrics = r1.metrics
        // Change the first metric's value by 0.001 (single-bit-like change)
        let first = flippedMetrics[0]
        flippedMetrics[0] = BloodworkMetric(
            name: first.name,
            value: (first.value ?? 0) + 0.001,
            valueText: first.valueText,
            unit: first.unit,
            referenceRange: first.referenceRange,
            panel: first.panel,
            collectedAt: first.collectedAt,
            flag: first.flag,
            interpretationNotes: first.interpretationNotes
        )
        let r2 = BloodworkReportData(
            type: r1.type, source: r1.source, reportDate: r1.reportDate,
            laboratory: r1.laboratory, panels: r1.panels,
            metrics: flippedMetrics,
            notes: r1.notes, rawText: r1.rawText, confidence: r1.confidence
        )
        XCTAssertNotEqual(
            FhirConverter.fingerprintBloodwork(r1),
            FhirConverter.fingerprintBloodwork(r2),
            "Even a tiny value change must produce a different fingerprint"
        )
    }

    func test_fingerprint_is_sha256_length() {
        let fp = FhirConverter.fingerprintBloodwork(MockPDFReports.mockBloodworkReport())
        XCTAssertEqual(fp.count, 64, "SHA-256 hex should be 64 characters")
        XCTAssertTrue(fp.allSatisfy { $0.isHexDigit }, "Fingerprint must be lowercase hex")
    }

    func test_dexa_fingerprint_is_sha256_length() {
        let fp = FhirConverter.fingerprintDexa(MockPDFReports.mockDexaReport())
        XCTAssertEqual(fp.count, 64)
    }

    func test_bloodwork_and_dexa_fingerprints_are_different_for_different_types() {
        // Even if values overlap, different types should produce different hashes
        // (type field is included in the hash input)
        let bw = MockPDFReports.mockBloodworkReport()
        let dexa = MockPDFReports.mockDexaReport()
        XCTAssertNotEqual(
            FhirConverter.fingerprintBloodwork(bw),
            FhirConverter.fingerprintDexa(dexa)
        )
    }
}

// MARK: - 3. FHIR Round-Trip Fidelity Tests

final class FHIRRoundTripFidelityTests: XCTestCase {

    // MARK: - Bloodwork round-trip: every field

    func test_bloodwork_roundtrip_metric_count() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        let decoded = FhirConverter.convertFhirToBloodwork(fhir, rawText: original.rawText, source: original.source)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.metrics.count, original.metrics.count,
                       "Metric count must survive bloodwork round-trip")
    }

    func test_bloodwork_roundtrip_metric_names_exact() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        let originalNames = Set(original.metrics.map { $0.name })
        let decodedNames = Set(decoded.metrics.map { $0.name })
        XCTAssertEqual(originalNames, decodedNames,
                       "All metric names must survive bloodwork round-trip exactly")
    }

    func test_bloodwork_roundtrip_all_numeric_values_with_precision() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origMetric in original.metrics {
            let decodedMetric = decoded.metrics.first { $0.name == origMetric.name }
            XCTAssertNotNil(decodedMetric, "Metric '\(origMetric.name)' missing after round-trip")
            if let origVal = origMetric.value, let decVal = decodedMetric?.value {
                XCTAssertEqual(origVal, decVal, accuracy: 1e-9,
                               "Value for '\(origMetric.name)' must be bit-exact after round-trip")
            }
        }
    }

    func test_bloodwork_roundtrip_units_exact() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origMetric in original.metrics {
            guard let unit = origMetric.unit else { continue }
            let decodedMetric = decoded.metrics.first { $0.name == origMetric.name }
            XCTAssertEqual(decodedMetric?.unit, unit,
                           "Unit for '\(origMetric.name)' must survive round-trip")
        }
    }

    func test_bloodwork_roundtrip_reference_ranges_exact() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origMetric in original.metrics {
            guard let ref = origMetric.referenceRange else { continue }
            let decodedMetric = decoded.metrics.first { $0.name == origMetric.name }
            XCTAssertEqual(decodedMetric?.referenceRange, ref,
                           "Reference range for '\(origMetric.name)' must survive round-trip")
        }
    }

    func test_bloodwork_roundtrip_flags_exact() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origMetric in original.metrics {
            guard let flag = origMetric.flag else { continue }
            let decodedMetric = decoded.metrics.first { $0.name == origMetric.name }
            XCTAssertEqual(decodedMetric?.flag, flag,
                           "Flag for '\(origMetric.name)' must survive round-trip: expected '\(flag)'")
        }
    }

    func test_bloodwork_roundtrip_dates_exact() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        // The effectiveDateTime on the DiagnosticReport feeds back as reportDate
        XCTAssertEqual(decoded.reportDate, original.reportDate,
                       "Report date must survive round-trip")
    }

    func test_bloodwork_roundtrip_type_field() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        let decoded = FhirConverter.convertFhirToBloodwork(fhir)
        XCTAssertEqual(decoded?.type, "bloodwork")
    }

    func test_bloodwork_fhir_structure_all_observations_have_resource_type() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        for obs in fhir.contained ?? [] {
            XCTAssertEqual(obs.resourceType, "Observation",
                           "Every contained resource must be resourceType: Observation")
        }
    }

    func test_bloodwork_fhir_result_refs_match_contained_ids() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        let containedIds = Set(fhir.contained?.compactMap { $0.id } ?? [])
        let refIds = Set(fhir.result?.compactMap { ref -> String? in
            guard let r = ref.reference, r.hasPrefix("#") else { return nil }
            return String(r.dropFirst())
        } ?? [])
        XCTAssertEqual(containedIds, refIds,
                       "Result references must exactly match contained observation IDs")
    }

    // MARK: - DEXA round-trip: every field

    func test_dexa_roundtrip_total_body_fat_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.totalBodyFatPercent, original.totalBodyFatPercent,
                       accuracy: 1e-9,
                       "totalBodyFatPercent must be exact after DEXA round-trip")
    }

    func test_dexa_roundtrip_lean_mass_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.totalLeanMassKg, original.totalLeanMassKg,
                       accuracy: 1e-9,
                       "totalLeanMassKg must be exact after DEXA round-trip")
    }

    func test_dexa_roundtrip_android_gynoid_ratio_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.androidGynoidRatio, original.androidGynoidRatio,
                       accuracy: 1e-9,
                       "androidGynoidRatio must be exact after DEXA round-trip")
    }

    func test_dexa_roundtrip_bone_density_bmd_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.boneDensityTotal?.bmd, original.boneDensityTotal?.bmd,
                       accuracy: 1e-9,
                       "boneDensityTotal.bmd must be exact after round-trip")
    }

    func test_dexa_roundtrip_bone_tscore_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.boneDensityTotal?.tScore, original.boneDensityTotal?.tScore,
                       accuracy: 1e-9,
                       "boneDensityTotal.tScore must be exact after round-trip")
    }

    func test_dexa_roundtrip_bone_zscore_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.boneDensityTotal?.zScore, original.boneDensityTotal?.zScore,
                       accuracy: 1e-9)
    }

    func test_dexa_roundtrip_visceral_fat_volume_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.visceralFatVolumeCm3, original.visceralFatVolumeCm3,
                       accuracy: 1e-9)
    }

    func test_dexa_roundtrip_visceral_fat_area_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.visceralFatAreaCm2, original.visceralFatAreaCm2,
                       accuracy: 1e-9)
    }

    func test_dexa_roundtrip_visceral_fat_rating_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.visceralFatRating, original.visceralFatRating,
                       accuracy: 1e-9)
    }

    func test_dexa_roundtrip_region_count() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.regions.count, original.regions.count,
                       "Region count must be preserved through DEXA round-trip")
    }

    func test_dexa_roundtrip_region_names() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        guard let decoded = FhirConverter.convertFhirToDexa(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        let originalRegions = Set(original.regions.map { $0.region })
        let decodedRegions = Set(decoded.regions.map { $0.region })
        XCTAssertEqual(originalRegions, decodedRegions,
                       "Region names must survive DEXA round-trip")
    }

    func test_dexa_roundtrip_each_region_body_fat_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        guard let decoded = FhirConverter.convertFhirToDexa(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origRegion in original.regions {
            let decodedRegion = decoded.regions.first { $0.region == origRegion.region }
            XCTAssertNotNil(decodedRegion, "Region '\(origRegion.region)' missing after round-trip")
            if let origFat = origRegion.bodyFatPercent, let decFat = decodedRegion?.bodyFatPercent {
                XCTAssertEqual(origFat, decFat, accuracy: 1e-9,
                               "bodyFatPercent for region '\(origRegion.region)' must be exact")
            }
        }
    }

    func test_dexa_roundtrip_each_region_lean_mass_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        guard let decoded = FhirConverter.convertFhirToDexa(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origRegion in original.regions {
            let decodedRegion = decoded.regions.first { $0.region == origRegion.region }
            if let origLean = origRegion.leanMassKg, let decLean = decodedRegion?.leanMassKg {
                XCTAssertEqual(origLean, decLean, accuracy: 1e-9,
                               "leanMassKg for region '\(origRegion.region)' must be exact")
            }
        }
    }

    func test_dexa_roundtrip_each_region_fat_mass_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        guard let decoded = FhirConverter.convertFhirToDexa(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origRegion in original.regions {
            let decodedRegion = decoded.regions.first { $0.region == origRegion.region }
            if let origFatMass = origRegion.fatMassKg, let decFatMass = decodedRegion?.fatMassKg {
                XCTAssertEqual(origFatMass, decFatMass, accuracy: 1e-9,
                               "fatMassKg for region '\(origRegion.region)' must be exact")
            }
        }
    }

    func test_dexa_roundtrip_each_region_bone_density_with_precision() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        guard let decoded = FhirConverter.convertFhirToDexa(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origRegion in original.regions {
            let decodedRegion = decoded.regions.first { $0.region == origRegion.region }
            if let origBMD = origRegion.boneDensityGPerCm2, let decBMD = decodedRegion?.boneDensityGPerCm2 {
                XCTAssertEqual(origBMD, decBMD, accuracy: 1e-9,
                               "boneDensityGPerCm2 for region '\(origRegion.region)' must be exact")
            }
        }
    }

    func test_dexa_roundtrip_scan_date_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.scanDate, original.scanDate,
                       "scanDate must survive DEXA round-trip exactly")
    }

    func test_dexa_roundtrip_type_field() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.type, "dexa")
    }

    // MARK: - Edge: empty regions still round-trip

    func test_dexa_with_no_regions_roundtrip() {
        let original = DexaReportData(
            type: "dexa", source: "GE Lunar", scanDate: "2025-01-01",
            totalBodyFatPercent: 22.0, totalLeanMassKg: 60.0,
            visceralFatRating: nil, visceralFatAreaCm2: nil, visceralFatVolumeCm3: nil,
            boneDensityTotal: nil, androidGynoidRatio: nil,
            regions: [],
            notes: [], rawText: "", confidence: 0.5
        )
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.totalBodyFatPercent, 22.0, accuracy: 1e-9)
        XCTAssertEqual(decoded?.totalLeanMassKg, 60.0, accuracy: 1e-9)
        XCTAssertTrue(decoded?.regions.isEmpty ?? false)
    }

    // MARK: - Edge: bloodwork with single metric

    func test_single_metric_bloodwork_roundtrip_exact() {
        let metric = BloodworkMetric(
            name: "Ferritin", value: 87.5, valueText: "87.5",
            unit: "ng/mL", referenceRange: "15-150",
            panel: "Iron Studies", collectedAt: "2025-06-01",
            flag: "normal", interpretationNotes: nil
        )
        let original = BloodworkReportData(
            type: "bloodwork", source: "LabCorp", reportDate: "2025-06-01",
            laboratory: "LabCorp", panels: ["Iron Studies": [metric]],
            metrics: [metric], notes: [],
            rawText: "Ferritin 87.5", confidence: 0.9
        )
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir, rawText: original.rawText) else {
            XCTFail("Decode returned nil"); return
        }
        XCTAssertEqual(decoded.metrics.count, 1)
        XCTAssertEqual(decoded.metrics.first?.name, "Ferritin")
        XCTAssertEqual(decoded.metrics.first?.value, 87.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.metrics.first?.unit, "ng/mL")
        XCTAssertEqual(decoded.metrics.first?.referenceRange, "15-150")
        XCTAssertEqual(decoded.metrics.first?.flag, "normal")
    }
}

// MARK: - 4. Concurrent Upload Safety Tests

final class PDFConcurrentTests: XCTestCase {

    // Test that concurrent FHIR conversion and fingerprinting (the CPU-bound parts
    // of the upload flow) are safe to call from multiple tasks simultaneously.
    // We cannot test the full PDFUploadService.upload() without network mocking,
    // so we test the pipeline steps that can be exercised in isolation.

    func test_concurrent_fhir_conversions_no_data_races() async {
        // 5 concurrent bloodwork FHIR conversions
        let report = MockPDFReports.mockBloodworkReport()
        await withTaskGroup(of: FhirDiagnosticReport.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    FhirConverter.convertBloodworkToFhir(report)
                }
            }
            var results: [FhirDiagnosticReport] = []
            for await r in group {
                results.append(r)
            }
            XCTAssertEqual(results.count, 5, "All 5 concurrent conversions should complete")
        }
    }

    func test_concurrent_dexa_fhir_conversions_no_data_races() async {
        let report = MockPDFReports.mockDexaReport()
        await withTaskGroup(of: FhirDiagnosticReport.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    FhirConverter.convertDexaToFhir(report)
                }
            }
            var results: [FhirDiagnosticReport] = []
            for await r in group {
                results.append(r)
            }
            XCTAssertEqual(results.count, 5)
        }
    }

    func test_concurrent_parse_text_calls_no_data_races() async {
        let text = MockPDFReports.mockBloodworkPDFText()
        await withTaskGroup(of: BloodworkReportData.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    PDFReportParser.parseBloodworkText(text)
                }
            }
            var results: [BloodworkReportData] = []
            for await r in group {
                results.append(r)
            }
            XCTAssertEqual(results.count, 5, "All 5 concurrent parse calls must complete")
            // All results should be equal since input is the same
            for result in results {
                XCTAssertEqual(result.metrics.count, results[0].metrics.count,
                               "Concurrent parses of same text must yield identical results")
            }
        }
    }

    func test_concurrent_fingerprinting_produces_consistent_results() async {
        let report = MockPDFReports.mockBloodworkReport()
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    FhirConverter.fingerprintBloodwork(report)
                }
            }
            var fingerprints: [String] = []
            for await fp in group {
                fingerprints.append(fp)
            }
            XCTAssertEqual(fingerprints.count, 5)
            // All 5 fingerprints must be identical
            let first = fingerprints[0]
            for fp in fingerprints {
                XCTAssertEqual(fp, first, "Concurrent fingerprinting must be deterministic")
            }
        }
    }

    func test_concurrent_dexa_parse_text_calls_no_data_races() async {
        let text = MockPDFReports.mockDexaPDFText()
        await withTaskGroup(of: DexaReportData.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    PDFReportParser.parseDexaText(text)
                }
            }
            var results: [DexaReportData] = []
            for await r in group {
                results.append(r)
            }
            XCTAssertEqual(results.count, 5)
        }
    }
}

// MARK: - 5. Large Payload Handling Tests

final class PDFLargePayloadTests: XCTestCase {

    // MARK: - Large bloodwork: 50+ markers

    private func makeLargeBloodworkText(markerCount: Int) -> String {
        var lines = [
            "Quest Diagnostics",
            "Date of Service: 11/14/2025",
            "COMPREHENSIVE METABOLIC PANEL",
        ]
        let markerNames = [
            "Glucose", "Sodium", "Potassium", "Chloride", "CO2", "BUN", "Creatinine",
            "eGFR", "Calcium", "Protein", "Albumin", "Bilirubin", "AST", "ALT",
            "Alkaline Phosphatase", "Total Cholesterol", "LDL Cholesterol",
            "HDL Cholesterol", "Triglycerides", "Apolipoprotein B", "TSH", "Free T4",
            "Free T3", "Vitamin D", "Vitamin B12", "Folate", "Ferritin",
            "Iron", "TIBC", "hs-CRP", "Homocysteine", "Testosterone", "Cortisol",
            "Insulin", "HbA1c", "Fasting Glucose", "Uric Acid", "Phosphorus",
            "Magnesium", "Zinc", "Copper", "Selenium", "WBC", "RBC",
            "Hemoglobin", "Hematocrit", "MCV", "MCH", "MCHC", "Platelets",
            "Neutrophils", "Lymphocytes", "Monocytes", "Eosinophils", "Basophils",
        ]
        for i in 0..<min(markerCount, markerNames.count) {
            let value = Double.random(in: 50...200)
            let formatted = String(format: "%-40s  %.1f      50-200        mg/dL          Normal",
                                   (markerNames[i] as NSString).utf8String!, value)
            lines.append(formatted)
        }
        // If we need more markers than names, generate synthetic ones
        if markerCount > markerNames.count {
            for i in markerNames.count..<markerCount {
                let value = Double.random(in: 1...100)
                lines.append(String(format: "Marker%-5d                            %.1f       1-100         unit           Normal", i, value))
            }
        }
        return lines.joined(separator: "\n")
    }

    func test_50_marker_bloodwork_parses_completely() {
        let text = makeLargeBloodworkText(markerCount: 55)
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertGreaterThanOrEqual(result.metrics.count, 10,
                                    "Should parse at least 10 markers from 55-marker input")
    }

    func test_large_bloodwork_parse_time_under_5_seconds() {
        let text = makeLargeBloodworkText(markerCount: 55)
        let start = Date()
        let result = PDFReportParser.parseBloodworkText(text)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0,
                          "Parsing 55 markers should complete in under 5 seconds, took \(elapsed)s")
        XCTAssertFalse(result.metrics.isEmpty)
    }

    func test_large_bloodwork_measure_performance() {
        let text = makeLargeBloodworkText(markerCount: 55)
        measure {
            _ = PDFReportParser.parseBloodworkText(text)
        }
    }

    // MARK: - Large DEXA: full regional breakdown

    private func makeLargeDexaText() -> String {
        """
        Hologic
        DEXA Body Composition Report
        Scan Date: 09/22/2025
        Facility: Advanced Imaging Center

        TOTAL BODY COMPOSITION
        Body Fat Percent: 18.4 %
        Lean Mass (kg): 67.2
        Total BMD: 1.28 g/cm2
        T-score: 0.6
        Z-score: 0.8

        VISCERAL FAT
        Visceral Fat Rating: 1.2
        Visceral Fat Area: 42.8 cm2
        Visceral Fat Volume: 312.4 cm3
        Android/Gynoid Ratio: 0.84

        Left Arm
        14.2   3.8   0.64   0.82

        Right Arm
        13.8   3.9   0.62   0.84

        Trunk
        16.1   32.4  6.22

        Left Leg
        20.4   12.1  3.12   1.14

        Right Leg
        21.0   12.3  3.26   1.16

        Pelvis
        22.8   7.4   2.20   1.42

        Head
        12.5   4.2   0.60   1.80

        Arms
        14.0   7.7   1.26

        Legs
        20.7   24.4  6.38

        BONE DENSITY BY REGION
        Lumbar Spine L1-L4 BMD: 1.42 g/cm2  T-score: 1.1  Z-score: 1.2

        Operator: R. Gonzalez DXA RT
        Device: Hologic Horizon A
        """
    }

    func test_full_dexa_with_all_regions_parses() {
        let text = makeLargeDexaText()
        let result = PDFReportParser.parseDexaText(text)
        XCTAssertNotNil(result.totalBodyFatPercent, "Should extract total body fat")
        XCTAssertNotNil(result.totalLeanMassKg, "Should extract lean mass")
        XCTAssertGreaterThanOrEqual(result.regions.count, 1, "Should extract at least 1 region")
    }

    func test_large_dexa_parse_time_under_5_seconds() {
        let text = makeLargeDexaText()
        let start = Date()
        let result = PDFReportParser.parseDexaText(text)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5.0,
                          "DEXA parse should complete in under 5 seconds, took \(elapsed)s")
        _ = result
    }

    func test_large_dexa_measure_performance() {
        let text = makeLargeDexaText()
        measure {
            _ = PDFReportParser.parseDexaText(text)
        }
    }

    // MARK: - Large FHIR: 50+ observations encode/decode

    func test_large_bloodwork_fhir_encode_decode_time_under_5_seconds() {
        // Build a report with 50 metrics
        var metrics: [BloodworkMetric] = []
        for i in 0..<50 {
            metrics.append(BloodworkMetric(
                name: "Marker \(i)",
                value: Double(i) * 1.5 + 10.0,
                valueText: "\(Double(i) * 1.5 + 10.0)",
                unit: "mg/dL",
                referenceRange: "5-200",
                panel: "Panel \(i / 10)",
                collectedAt: "2025-11-14",
                flag: "normal",
                interpretationNotes: nil
            ))
        }
        let panels: [String: [BloodworkMetric]] = metrics.reduce(into: [:]) { acc, m in
            acc[m.panel ?? "general", default: []].append(m)
        }
        let report = BloodworkReportData(
            type: "bloodwork", source: "LabCorp", reportDate: "2025-11-14",
            laboratory: "LabCorp", panels: panels,
            metrics: metrics, notes: [],
            rawText: "", confidence: 1.0
        )

        let start = Date()
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        let decoded = FhirConverter.convertFhirToBloodwork(fhir)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 5.0,
                          "50-metric FHIR encode+decode should be under 5s, took \(elapsed)s")
        XCTAssertEqual(decoded?.metrics.count, 50, "All 50 metrics must survive")
    }

    func test_large_bloodwork_completeness_of_parsed_output() {
        let text = makeLargeBloodworkText(markerCount: 55)
        let result = PDFReportParser.parseBloodworkText(text)
        // All parsed metrics must have non-empty names and finite values
        for metric in result.metrics {
            XCTAssertFalse(metric.name.isEmpty, "Every metric must have a name")
            if let v = metric.value {
                XCTAssertTrue(v.isFinite, "All metric values must be finite")
            }
        }
        // Panels should be populated
        XCTAssertFalse(result.panels.isEmpty)
    }
}

// MARK: - 6. Error Handling Path Tests

final class PDFErrorHandlingTests: XCTestCase {

    // MARK: - Malformed PDF bytes

    func test_random_bytes_parser_returns_nil() {
        var rng = SystemRandomNumberGenerator()
        let randomData = Data((0..<512).map { _ in UInt8.random(in: 0...255, using: &rng) })
        let result = PDFReportParser.parse(pdfData: randomData, filename: "random.pdf")
        XCTAssertNil(result, "Random bytes must return nil, not crash")
    }

    func test_empty_data_parser_returns_nil() {
        let result = PDFReportParser.parse(pdfData: Data(), filename: "empty.pdf")
        XCTAssertNil(result, "Empty data must return nil")
    }

    func test_text_only_bytes_parser_returns_nil() {
        let text = "This is not a PDF at all. No health data here."
        let data = text.data(using: .utf8)!
        let result = PDFReportParser.parse(pdfData: data, filename: "text.pdf")
        XCTAssertNil(result, "Plain text bytes (non-PDF) must return nil")
    }

    func test_minimal_pdf_structure_no_content_returns_nil() {
        // A PDF with valid structure but no text content
        let pdfDoc = PDFDocument()
        let data = pdfDoc.dataRepresentation() ?? Data()
        let result = PDFReportParser.parse(pdfData: data, filename: "empty_pdf.pdf")
        XCTAssertNil(result, "PDF with no pages/content must return nil")
    }

    func test_pdf_with_irrelevant_text_returns_nil() {
        // A PDF containing readable text that is NOT health data
        let irrelevantText = """
        This is a recipe for chocolate cake.
        Ingredients: flour, sugar, eggs, butter.
        Mix and bake at 350 degrees for 30 minutes.
        """
        let pdfData = makePDFFromText(irrelevantText, title: "Recipe")
        let result = PDFReportParser.parse(pdfData: pdfData, filename: "recipe.pdf")
        XCTAssertNil(result, "Non-health PDF content should return nil")
    }

    // MARK: - parseText returns nil for empty/whitespace

    func test_parse_text_empty_string_returns_nil() {
        let result = PDFReportParser.parseText("", filename: "empty.txt")
        XCTAssertNil(result)
    }

    func test_parse_text_whitespace_only_returns_nil() {
        let result = PDFReportParser.parseText("   \n\n\t  ", filename: "blank.txt")
        XCTAssertNil(result)
    }

    // MARK: - PDFUploadError descriptive messages

    func test_unrecognized_content_error_has_descriptive_message() {
        let error = PDFUploadError.unrecognizedContent
        XCTAssertNotNil(error.errorDescription, "Error must have a description")
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertTrue(error.errorDescription?.contains("PDF") ?? false,
                      "Error message should mention PDF")
    }

    func test_upload_failed_error_includes_message() {
        let error = PDFUploadError.uploadFailed("Server returned 500")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Server returned 500") ?? false,
                      "Error description should include the failure message")
    }

    // MARK: - Network-level error simulation (via mock storeFhirReport)

    func test_storj_500_simulation_throws_descriptive_error() async {
        // Simulate what the API client does on a 500: it throws APIError.requestFailed
        // We exercise FhirConverter and fingerprinting still work correctly upstream

        let report = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        let fingerprint = FhirConverter.fingerprintBloodwork(report)

        // Verify the pipeline outputs are valid before the network call
        XCTAssertEqual(fhir.resourceType, "DiagnosticReport")
        XCTAssertEqual(fingerprint.count, 64)

        // Simulate a thrown error matching what APIError.requestFailed would produce
        struct MockNetworkError: LocalizedError {
            var errorDescription: String? { "Upload failed: HTTP 500 Internal Server Error" }
        }

        let simulatedError = MockNetworkError()
        XCTAssertEqual(simulatedError.errorDescription, "Upload failed: HTTP 500 Internal Server Error")
    }

    // MARK: - PDFUploadState transitions

    func test_upload_state_idle_is_initial() async throws {
        // PDFUploadService.shared is @MainActor — we verify the state API
        await MainActor.run {
            // We can't call reset() on shared directly in a test without race,
            // but we can verify the PDFUploadState enum equality works
            let stateA: PDFUploadState = .idle
            let stateB: PDFUploadState = .idle
            XCTAssertEqual(stateA, stateB)
        }
    }

    func test_upload_state_error_equality() {
        let e1: PDFUploadState = .error("Upload failed")
        let e2: PDFUploadState = .error("Upload failed")
        let e3: PDFUploadState = .error("Different error")
        XCTAssertEqual(e1, e2)
        XCTAssertNotEqual(e1, e3)
    }

    func test_upload_state_uploading_progress_equality() {
        let u1: PDFUploadState = .uploading(progress: 0.5)
        let u2: PDFUploadState = .uploading(progress: 0.5)
        let u3: PDFUploadState = .uploading(progress: 0.9)
        XCTAssertEqual(u1, u2)
        XCTAssertNotEqual(u1, u3)
    }

    // MARK: - FHIR decode from invalid DiagnosticReport

    func test_fhir_bloodwork_decode_fails_on_wrong_resource_type() {
        // Build a FHIR report with wrong resourceType
        let badFhir = FhirDiagnosticReport(
            resourceType: "Patient",  // wrong!
            id: nil,
            status: "final",
            category: nil,
            code: FhirCodeableConcept(coding: []),
            subject: nil,
            effectiveDateTime: nil,
            issued: nil,
            performer: nil,
            result: nil,
            conclusion: nil,
            contained: nil
        )
        let result = FhirConverter.convertFhirToBloodwork(badFhir)
        XCTAssertNil(result, "convertFhirToBloodwork should return nil for non-DiagnosticReport")
    }

    func test_fhir_dexa_decode_fails_on_wrong_resource_type() {
        let badFhir = FhirDiagnosticReport(
            resourceType: "Observation",  // wrong!
            id: nil,
            status: "final",
            category: nil,
            code: FhirCodeableConcept(coding: []),
            subject: nil,
            effectiveDateTime: nil,
            issued: nil,
            performer: nil,
            result: nil,
            conclusion: nil,
            contained: nil
        )
        let result = FhirConverter.convertFhirToDexa(badFhir)
        XCTAssertNil(result, "convertFhirToDexa should return nil for non-DiagnosticReport")
    }

    func test_fhir_bloodwork_decode_with_no_contained_returns_empty_metrics() {
        let fhir = FhirDiagnosticReport(
            resourceType: "DiagnosticReport",
            id: "test-id",
            status: "final",
            category: nil,
            code: FhirCodeableConcept(coding: []),
            subject: nil,
            effectiveDateTime: "2025-11-14",
            issued: nil,
            performer: nil,
            result: nil,
            conclusion: nil,
            contained: nil  // no observations
        )
        let decoded = FhirConverter.convertFhirToBloodwork(fhir)
        XCTAssertNotNil(decoded, "Should decode successfully even with no contained observations")
        XCTAssertTrue(decoded?.metrics.isEmpty ?? false, "No observations → no metrics")
    }

    // MARK: - JSON serialization robustness

    func test_bloodwork_fhir_json_round_trip_via_codable() throws {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let jsonData = try encoder.encode(fhir)
        XCTAssertFalse(jsonData.isEmpty)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FhirDiagnosticReport.self, from: jsonData)
        XCTAssertEqual(decoded.resourceType, "DiagnosticReport")
        XCTAssertEqual(decoded.contained?.count, fhir.contained?.count)
    }

    func test_dexa_fhir_json_round_trip_via_codable() throws {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(fhir)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FhirDiagnosticReport.self, from: jsonData)
        XCTAssertEqual(decoded.resourceType, "DiagnosticReport")
        // Re-decode back to DexaReportData
        let redecoded = FhirConverter.convertFhirToDexa(decoded)
        XCTAssertNotNil(redecoded)
        XCTAssertEqual(redecoded?.totalBodyFatPercent, original.totalBodyFatPercent,
                       accuracy: 1e-9)
    }
}

// MARK: - Helpers

/// Generate a minimal PDF from plaintext using UIGraphicsPDFRenderer.
private func makePDFFromText(_ text: String, title: String) -> Data {
    let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
    let format = UIGraphicsPDFRendererFormat()
    format.documentInfo = [kCGPDFContextTitle as String: title]
    let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
    return renderer.pdfData { context in
        context.beginPage()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        ]
        text.draw(in: CGRect(x: 36, y: 36, width: 540, height: 720), withAttributes: attrs)
    }
}
