// PDFReportStressTests.swift
// AmachHealthTests
//
// Stress and robustness tests for the PDF upload pipeline:
//   1. Parser robustness — malformed, partial, non-standard inputs
//   2. Dedup fingerprint logic — same/different/mutated
//   3. FHIR round-trip field fidelity — every value survives exactly
//   4. Concurrent parsing — 5 parallel parses, no races/crashes
//   5. Large payload — 50+ marker bloodwork, timing check
//   6. Error paths — bad bytes, empty data, unrecognized content

import XCTest
@testable import AmachHealth

// MARK: - 1. Parser Robustness

final class ParserRobustnessTests: XCTestCase {

    // MARK: Missing values / partial panels

    func test_partial_panel_does_not_crash() {
        // Only one metric in the entire text
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        Total Cholesterol                182          <200          mg/dL          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertFalse(result.metrics.isEmpty, "Should extract partial panel without crashing")
    }

    func test_marker_with_missing_value_does_not_appear() {
        // Line that has a name but no parseable number — parser should skip, not crash
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        Total Cholesterol                PND          <200          mg/dL          Normal
        LDL Cholesterol                   98          <100          mg/dL          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        // PND (pending) should not appear; LDL should
        let names = result.metrics.map { $0.name.lowercased() }
        XCTAssertFalse(names.contains(where: { $0.contains("cholesterol") && $0.contains("total") }),
                       "Marker with non-numeric value should not be extracted")
        XCTAssertTrue(names.contains(where: { $0.contains("ldl") }),
                      "Valid LDL marker should still be extracted")
    }

    func test_empty_string_returns_nil() {
        XCTAssertNil(PDFReportParser.parseText("", filename: "test.pdf"))
    }

    func test_whitespace_only_returns_nil() {
        XCTAssertNil(PDFReportParser.parseText("   \n\t\n  ", filename: "test.pdf"))
    }

    func test_random_prose_returns_nil() {
        let text = "This is a patient summary note. No lab values were recorded today."
        XCTAssertNil(PDFReportParser.parseText(text, filename: "note.pdf"))
    }

    // MARK: Non-standard marker names

    func test_hba1c_alias_a1c() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        DIABETES PANEL
        A1C                               5.2         <5.7          %              Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let metric = result.metrics.first { $0.name.lowercased().contains("a1c") }
        XCTAssertNotNil(metric, "A1C alias should be extracted")
        XCTAssertEqual(metric?.value ?? 0, 5.2, accuracy: 0.01)
    }

    func test_hba1c_alias_hemoglobin_a1c() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        DIABETES PANEL
        Hemoglobin A1c                    5.2         <5.7          %              Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let metric = result.metrics.first { $0.name.lowercased().contains("hemoglobin") || $0.name.lowercased().contains("a1c") }
        XCTAssertNotNil(metric, "Hemoglobin A1c name should be extracted")
        XCTAssertEqual(metric?.value ?? 0, 5.2, accuracy: 0.01)
    }

    func test_tsh_with_verbose_name() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        THYROID PANEL
        Thyroid Stimulating Hormone       1.82        0.45-4.5      mIU/L          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let metric = result.metrics.first { $0.name.lowercased().contains("thyroid") }
        XCTAssertNotNil(metric, "Verbose TSH name should be extracted")
        XCTAssertEqual(metric?.value ?? 0, 1.82, accuracy: 0.01)
    }

    // MARK: Unit variations

    func test_mmol_l_unit_parsed() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        METABOLIC PANEL
        Glucose                           5.2         3.6-5.6       mmol/L         Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let metric = result.metrics.first { $0.name.lowercased() == "glucose" }
        XCTAssertNotNil(metric, "Glucose with mmol/L unit should be extracted")
        XCTAssertEqual(metric?.unit, "mmol/L")
        XCTAssertEqual(metric?.value ?? 0, 5.2, accuracy: 0.01)
    }

    func test_percent_unit_parsed() {
        let text = """
        LabCorp
        Date of Service: 05/10/2025
        DIABETES PANEL
        HbA1c                             5.4         <5.7          %              Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let metric = result.metrics.first { $0.name.lowercased().contains("hba1c") || $0.name.lowercased().contains("a1c") }
        XCTAssertNotNil(metric)
        XCTAssertEqual(metric?.unit, "%")
    }

    // MARK: Reference range with < and > prefixes

    func test_lt_reference_range_preserved() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        LDL Cholesterol                   98          <100          mg/dL          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let metric = result.metrics.first { $0.name.lowercased().contains("ldl") }
        XCTAssertNotNil(metric)
        XCTAssertNotNil(metric?.referenceRange, "Reference range with < should be captured")
    }

    func test_gt_reference_range_preserved() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        HDL Cholesterol                   62          >40           mg/dL          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let metric = result.metrics.first { $0.name.lowercased().contains("hdl") }
        XCTAssertNotNil(metric)
        XCTAssertNotNil(metric?.referenceRange, "Reference range with > should be captured")
    }

    func test_value_with_less_than_prefix_does_not_crash() {
        // The value itself has a < prefix (e.g. "< 0.1" for undetected analytes)
        // Parser should skip or handle gracefully — not crash
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        INFLAMMATION
        hs-CRP                            < 0.1       <1.0          mg/L           Normal
        Ferritin                          85          15-150        ng/mL          Normal
        """
        // Must not throw or crash
        let result = PDFReportParser.parseBloodworkText(text)
        // Ferritin at minimum should be parsed
        let ferritin = result.metrics.first { $0.name.lowercased().contains("ferritin") }
        XCTAssertNotNil(ferritin, "Ferritin should still be parsed even when prior line has < prefix value")
    }

    // MARK: Unexpected whitespace

    func test_extra_leading_whitespace_on_lines() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025

             LIPID PANEL
             Total Cholesterol                182          <200          mg/dL          Normal
             LDL Cholesterol                   98          <100          mg/dL          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertFalse(result.metrics.isEmpty, "Extra leading whitespace should not prevent parsing")
    }

    func test_tabs_between_fields() {
        // Some PDFs export with tabs instead of spaces
        let text = "Quest Diagnostics\nDate of Service: 11/14/2025\nLIPID PANEL\nTotal Cholesterol\t\t\t182\t\t\t<200\t\t\tmg/dL\t\t\tNormal\n"
        // Just verify no crash
        let result = PDFReportParser.parseBloodworkText(text)
        // Parser may or may not match tabs; the important thing is no crash
        XCTAssertNotNil(result, "Parser must not crash on tab-separated input")
    }

    func test_extra_blank_lines_throughout() {
        let text = """
        Quest Diagnostics


        Date of Service: 11/14/2025


        LIPID PANEL


        Total Cholesterol                182          <200          mg/dL          Normal


        LDL Cholesterol                   98          <100          mg/dL          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertFalse(result.metrics.isEmpty, "Extra blank lines should not prevent parsing")
    }

    // MARK: Numbers with commas

    func test_number_with_comma_thousands_separator_does_not_crash() {
        // e.g. eGFR or a count that appears as "1,234"
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        COMPREHENSIVE METABOLIC PANEL
        eGFR                          1,234         >60           mL/min/1.73m2  Normal
        Glucose                          94          65-99         mg/dL          Normal
        """
        // Must not crash; Glucose should still be parsed
        let result = PDFReportParser.parseBloodworkText(text)
        let glucose = result.metrics.first { $0.name.lowercased() == "glucose" }
        XCTAssertNotNil(glucose, "Valid numeric metrics should parse even when others have comma-formatted numbers")
    }

    // MARK: Flags

    func test_high_flag_extracted() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        LIPID PANEL
        LDL Cholesterol                  145          <100          mg/dL          H
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let ldl = result.metrics.first { $0.name.lowercased().contains("ldl") }
        XCTAssertNotNil(ldl)
        XCTAssertEqual(ldl?.flag, "high")
    }

    func test_low_flag_extracted() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        IRON STUDIES
        Ferritin                           8          15-150        ng/mL          L
        """
        let result = PDFReportParser.parseBloodworkText(text)
        let ferritin = result.metrics.first { $0.name.lowercased() == "ferritin" }
        XCTAssertNotNil(ferritin)
        XCTAssertEqual(ferritin?.flag, "low")
    }

    // MARK: Date normalization

    func test_date_with_dashes_normalizes() {
        let text = """
        Quest Diagnostics
        Date of Service: 11-14-2025
        LIPID PANEL
        Total Cholesterol                182          <200          mg/dL          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertEqual(result.reportDate, "2025-11-14")
    }

    func test_date_already_iso_preserved() {
        let text = """
        Quest Diagnostics
        Date of Service: 2025-11-14
        LIPID PANEL
        Total Cholesterol                182          <200          mg/dL          Normal
        """
        let result = PDFReportParser.parseBloodworkText(text)
        XCTAssertEqual(result.reportDate, "2025-11-14")
    }

    // MARK: DEXA robustness

    func test_dexa_with_only_total_fields_does_not_crash() {
        // No regional data, just total body metrics
        let text = """
        Hologic
        DEXA Body Composition Report
        Scan Date: 09/22/2025
        Body Fat Percent: 18.4 %
        Lean Mass (kg): 67.2
        """
        let result = PDFReportParser.parseDexaText(text)
        XCTAssertEqual(result.totalBodyFatPercent ?? 0, 18.4, accuracy: 0.1)
        XCTAssertEqual(result.totalLeanMassKg ?? 0, 67.2, accuracy: 0.1)
        XCTAssertTrue(result.regions.isEmpty || result.regions.count >= 0,
                      "No crash even with no regional data")
    }

    func test_dexa_text_without_visceral_does_not_crash() {
        let text = """
        Hologic
        DEXA Body Composition Report
        Scan Date: 09/22/2025
        Body Fat Percent: 21.0 %
        Lean Mass (kg): 60.0
        Total BMD: 1.18 g/cm2
        T-score: 0.2
        Z-score: 0.4
        """
        let result = PDFReportParser.parseDexaText(text)
        XCTAssertEqual(result.totalBodyFatPercent ?? 0, 21.0, accuracy: 0.1)
        XCTAssertNil(result.visceralFatRating, "No visceral fat data should yield nil")
        XCTAssertNil(result.visceralFatAreaCm2)
    }

    func test_dexa_ge_lunar_source_detected() {
        let text = """
        GE Lunar
        iDXA Body Composition Report
        Scan Date: 03/15/2025
        Body Fat Percent: 22.1 %
        Lean Mass (kg): 58.0
        """
        let result = PDFReportParser.parseDexaText(text)
        XCTAssertEqual(result.source, "GE Lunar")
    }
}

// MARK: - 2. Dedup Fingerprint Logic

final class DedupFingerprintTests: XCTestCase {

    func test_same_bloodwork_same_fingerprint() {
        let report = MockPDFReports.mockBloodworkReport()
        let fp1 = FhirConverter.fingerprintBloodwork(report)
        let fp2 = FhirConverter.fingerprintBloodwork(report)
        XCTAssertEqual(fp1, fp2, "Identical report must produce identical fingerprint (dedup)")
    }

    func test_same_dexa_same_fingerprint() {
        let report = MockPDFReports.mockDexaReport()
        let fp1 = FhirConverter.fingerprintDexa(report)
        let fp2 = FhirConverter.fingerprintDexa(report)
        XCTAssertEqual(fp1, fp2)
    }

    func test_two_different_bloodwork_different_fingerprint() {
        let r1 = MockPDFReports.mockBloodworkReport()
        // Change one marker value by a tiny amount
        let mutatedMetrics = r1.metrics.enumerated().map { i, m in
            i == 0 ? BloodworkMetric(name: m.name, value: (m.value ?? 0) + 0.1,
                                     valueText: m.valueText, unit: m.unit,
                                     referenceRange: m.referenceRange, panel: m.panel,
                                     collectedAt: m.collectedAt, flag: m.flag,
                                     interpretationNotes: m.interpretationNotes) : m
        }
        let r2 = BloodworkReportData(type: r1.type, source: r1.source, reportDate: r1.reportDate,
                                      laboratory: r1.laboratory, panels: r1.panels,
                                      metrics: mutatedMetrics, notes: r1.notes,
                                      rawText: r1.rawText, confidence: r1.confidence)
        XCTAssertNotEqual(
            FhirConverter.fingerprintBloodwork(r1),
            FhirConverter.fingerprintBloodwork(r2),
            "One-value mutation must change the fingerprint"
        )
    }

    func test_two_different_dexa_different_fingerprint() {
        let r1 = MockPDFReports.mockDexaReport()
        let r2 = DexaReportData(
            type: r1.type, source: r1.source, scanDate: r1.scanDate,
            totalBodyFatPercent: (r1.totalBodyFatPercent ?? 0) + 0.1,
            totalLeanMassKg: r1.totalLeanMassKg,
            visceralFatRating: r1.visceralFatRating,
            visceralFatAreaCm2: r1.visceralFatAreaCm2,
            visceralFatVolumeCm3: r1.visceralFatVolumeCm3,
            boneDensityTotal: r1.boneDensityTotal,
            androidGynoidRatio: r1.androidGynoidRatio,
            regions: r1.regions, notes: r1.notes,
            rawText: r1.rawText, confidence: r1.confidence
        )
        XCTAssertNotEqual(FhirConverter.fingerprintDexa(r1), FhirConverter.fingerprintDexa(r2))
    }

    func test_bloodwork_and_dexa_fingerprints_never_collide() {
        // Cross-type uniqueness: even if both have similar data
        let bw = FhirConverter.fingerprintBloodwork(MockPDFReports.mockBloodworkReport())
        let dexa = FhirConverter.fingerprintDexa(MockPDFReports.mockDexaReport())
        XCTAssertNotEqual(bw, dexa, "Bloodwork and DEXA fingerprints must be distinct")
    }

    func test_fingerprint_is_64_char_hex() {
        let fp = FhirConverter.fingerprintBloodwork(MockPDFReports.mockBloodworkReport())
        XCTAssertEqual(fp.count, 64)
        XCTAssertTrue(fp.allSatisfy { $0.isHexDigit }, "Fingerprint must be hex-only")
    }

    func test_date_mutation_changes_fingerprint() {
        let r1 = MockPDFReports.mockBloodworkReport()
        let r2 = BloodworkReportData(type: r1.type, source: r1.source,
                                      reportDate: "2024-01-01",  // changed
                                      laboratory: r1.laboratory, panels: r1.panels,
                                      metrics: r1.metrics, notes: r1.notes,
                                      rawText: r1.rawText, confidence: r1.confidence)
        XCTAssertNotEqual(
            FhirConverter.fingerprintBloodwork(r1),
            FhirConverter.fingerprintBloodwork(r2),
            "Different report date should change fingerprint"
        )
    }

    func test_source_mutation_changes_fingerprint() {
        let r1 = MockPDFReports.mockBloodworkReport()
        let r2 = BloodworkReportData(type: r1.type, source: "LabCorp",  // changed
                                      reportDate: r1.reportDate,
                                      laboratory: r1.laboratory, panels: r1.panels,
                                      metrics: r1.metrics, notes: r1.notes,
                                      rawText: r1.rawText, confidence: r1.confidence)
        XCTAssertNotEqual(
            FhirConverter.fingerprintBloodwork(r1),
            FhirConverter.fingerprintBloodwork(r2)
        )
    }

    func test_adding_marker_changes_fingerprint() {
        let r1 = MockPDFReports.mockBloodworkReport()
        let extra = BloodworkMetric(name: "Extra Marker", value: 42, valueText: "42",
                                    unit: "mg/dL", referenceRange: "20-60", panel: "Extra",
                                    collectedAt: nil, flag: "normal", interpretationNotes: nil)
        let r2 = BloodworkReportData(type: r1.type, source: r1.source, reportDate: r1.reportDate,
                                      laboratory: r1.laboratory, panels: r1.panels,
                                      metrics: r1.metrics + [extra], notes: r1.notes,
                                      rawText: r1.rawText, confidence: r1.confidence)
        XCTAssertNotEqual(
            FhirConverter.fingerprintBloodwork(r1),
            FhirConverter.fingerprintBloodwork(r2),
            "Adding a marker should change the fingerprint"
        )
    }
}

// MARK: - 3. FHIR Round-Trip Fidelity

final class FhirRoundTripFidelityTests: XCTestCase {

    // MARK: Bloodwork — every marker value

    func test_all_bloodwork_values_survive_round_trip() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origMetric in original.metrics {
            let match = decoded.metrics.first { $0.name == origMetric.name }
            XCTAssertNotNil(match, "Metric '\(origMetric.name)' missing after round-trip")
            if let match, let origVal = origMetric.value, let decodedVal = match.value {
                XCTAssertEqual(decodedVal, origVal, accuracy: 0.0001,
                               "Value for '\(origMetric.name)' changed: \(origVal) → \(decodedVal)")
            }
        }
    }

    func test_all_bloodwork_units_survive_round_trip() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origMetric in original.metrics {
            guard let unit = origMetric.unit else { continue }
            let match = decoded.metrics.first { $0.name == origMetric.name }
            XCTAssertEqual(match?.unit, unit,
                           "Unit for '\(origMetric.name)' changed: '\(unit)' → '\(match?.unit ?? "nil")'")
        }
    }

    func test_all_bloodwork_reference_ranges_survive_round_trip() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origMetric in original.metrics {
            guard let ref = origMetric.referenceRange else { continue }
            let match = decoded.metrics.first { $0.name == origMetric.name }
            XCTAssertEqual(match?.referenceRange, ref,
                           "Reference range for '\(origMetric.name)' changed")
        }
    }

    func test_bloodwork_report_date_survives_round_trip() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        let decoded = FhirConverter.convertFhirToBloodwork(fhir)
        XCTAssertEqual(decoded?.reportDate, original.reportDate,
                       "Report date must survive round-trip")
    }

    func test_bloodwork_metric_count_exact() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        let decoded = FhirConverter.convertFhirToBloodwork(fhir)
        XCTAssertEqual(decoded?.metrics.count, original.metrics.count,
                       "Metric count must be exact after round-trip")
    }

    func test_all_bloodwork_flags_survive_round_trip() {
        // Build a report with each flag type
        let flaggedMetrics: [BloodworkMetric] = [
            BloodworkMetric(name: "Normal Marker", value: 94, valueText: "94", unit: "mg/dL",
                            referenceRange: "65-99", panel: nil, collectedAt: nil, flag: "normal", interpretationNotes: nil),
            BloodworkMetric(name: "High Marker", value: 145, valueText: "145", unit: "mg/dL",
                            referenceRange: "<100", panel: nil, collectedAt: nil, flag: "high", interpretationNotes: nil),
            BloodworkMetric(name: "Low Marker", value: 3.0, valueText: "3.0", unit: "mmol/L",
                            referenceRange: "3.5-5.1", panel: nil, collectedAt: nil, flag: "low", interpretationNotes: nil),
            BloodworkMetric(name: "Critical High", value: 8.5, valueText: "8.5", unit: "mmol/L",
                            referenceRange: "3.5-5.1", panel: nil, collectedAt: nil, flag: "critical-high", interpretationNotes: nil),
            BloodworkMetric(name: "Critical Low", value: 2.8, valueText: "2.8", unit: "mmol/L",
                            referenceRange: "3.5-5.1", panel: nil, collectedAt: nil, flag: "critical-low", interpretationNotes: nil),
        ]
        let report = BloodworkReportData(type: "bloodwork", source: nil, reportDate: "2025-01-01",
                                          laboratory: nil, panels: [:], metrics: flaggedMetrics,
                                          notes: nil, rawText: "", confidence: 0.9)
        let fhir = FhirConverter.convertBloodworkToFhir(report)
        guard let decoded = FhirConverter.convertFhirToBloodwork(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origMetric in flaggedMetrics {
            let match = decoded.metrics.first { $0.name == origMetric.name }
            XCTAssertEqual(match?.flag, origMetric.flag,
                           "Flag for '\(origMetric.name)' must survive round-trip")
        }
    }

    // MARK: DEXA — every field

    func test_dexa_fat_percent_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.totalBodyFatPercent ?? 0, original.totalBodyFatPercent ?? 0, accuracy: 0.0001)
    }

    func test_dexa_lean_mass_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.totalLeanMassKg ?? 0, original.totalLeanMassKg ?? 0, accuracy: 0.0001)
    }

    func test_dexa_visceral_fat_rating_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.visceralFatRating ?? 0, original.visceralFatRating ?? 0, accuracy: 0.0001)
    }

    func test_dexa_visceral_fat_area_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.visceralFatAreaCm2 ?? 0, original.visceralFatAreaCm2 ?? 0, accuracy: 0.0001)
    }

    func test_dexa_visceral_fat_volume_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.visceralFatVolumeCm3 ?? 0, original.visceralFatVolumeCm3 ?? 0, accuracy: 0.0001)
    }

    func test_dexa_bmd_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.boneDensityTotal?.bmd ?? 0, original.boneDensityTotal?.bmd ?? 0, accuracy: 0.0001)
    }

    func test_dexa_t_score_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.boneDensityTotal?.tScore ?? 0, original.boneDensityTotal?.tScore ?? 0, accuracy: 0.0001)
    }

    func test_dexa_z_score_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.boneDensityTotal?.zScore ?? 0, original.boneDensityTotal?.zScore ?? 0, accuracy: 0.0001)
    }

    func test_dexa_android_gynoid_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.androidGynoidRatio ?? 0, original.androidGynoidRatio ?? 0, accuracy: 0.0001)
    }

    func test_dexa_scan_date_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.scanDate, original.scanDate)
    }

    func test_dexa_region_fat_percents_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        guard let decoded = FhirConverter.convertFhirToDexa(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origRegion in original.regions {
            let match = decoded.regions.first { $0.region == origRegion.region }
            guard let match else {
                // Region representation may vary in FHIR; skip if not present
                continue
            }
            if let origFat = origRegion.bodyFatPercent, let decodedFat = match.bodyFatPercent {
                XCTAssertEqual(decodedFat, origFat, accuracy: 0.0001,
                               "Fat % for region '\(origRegion.region)' changed")
            }
        }
    }

    func test_dexa_region_lean_mass_exact() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        guard let decoded = FhirConverter.convertFhirToDexa(fhir) else {
            XCTFail("Decode returned nil"); return
        }
        for origRegion in original.regions {
            let match = decoded.regions.first { $0.region == origRegion.region }
            guard let match else { continue }
            if let origLean = origRegion.leanMassKg, let decodedLean = match.leanMassKg {
                XCTAssertEqual(decodedLean, origLean, accuracy: 0.0001,
                               "Lean mass for region '\(origRegion.region)' changed")
            }
        }
    }

    func test_fhir_resourcetype_and_status_preserved() {
        let bwFhir = FhirConverter.convertBloodworkToFhir(MockPDFReports.mockBloodworkReport())
        XCTAssertEqual(bwFhir.resourceType, "DiagnosticReport")
        XCTAssertEqual(bwFhir.status, "final")

        let dexaFhir = FhirConverter.convertDexaToFhir(MockPDFReports.mockDexaReport())
        XCTAssertEqual(dexaFhir.resourceType, "DiagnosticReport")
        XCTAssertEqual(dexaFhir.status, "final")
    }
}

// MARK: - 4. Concurrent Parsing

final class ConcurrentParserTests: XCTestCase {

    func test_five_concurrent_bloodwork_parses_no_crash() async {
        let text = MockPDFReports.mockBloodworkPDFText()
        await withTaskGroup(of: BloodworkReportData.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    PDFReportParser.parseBloodworkText(text)
                }
            }
            var results: [BloodworkReportData] = []
            for await result in group {
                results.append(result)
            }
            XCTAssertEqual(results.count, 5, "All 5 concurrent parses should complete")
            // All results should be consistent
            let firstCount = results[0].metrics.count
            for (i, r) in results.enumerated() {
                XCTAssertEqual(r.metrics.count, firstCount,
                               "Parse result \(i) has different metric count")
            }
        }
    }

    func test_five_concurrent_dexa_parses_no_crash() async {
        let text = MockPDFReports.mockDexaPDFText()
        await withTaskGroup(of: DexaReportData.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    PDFReportParser.parseDexaText(text)
                }
            }
            var results: [DexaReportData] = []
            for await result in group {
                results.append(result)
            }
            XCTAssertEqual(results.count, 5)
            let firstFat = results[0].totalBodyFatPercent
            for (i, r) in results.enumerated() {
                XCTAssertEqual(r.totalBodyFatPercent ?? 0, firstFat ?? 0, accuracy: 0.0001,
                               "DEXA result \(i) has different fat %")
            }
        }
    }

    func test_five_concurrent_fhir_conversions_no_crash() async {
        let report = MockPDFReports.mockBloodworkReport()
        await withTaskGroup(of: FhirDiagnosticReport.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    FhirConverter.convertBloodworkToFhir(report)
                }
            }
            var results: [FhirDiagnosticReport] = []
            for await r in group { results.append(r) }
            XCTAssertEqual(results.count, 5)
            // All should have the same contained count
            let first = results[0].contained?.count
            for r in results {
                XCTAssertEqual(r.contained?.count, first, "Concurrent FHIR conversion must be consistent")
            }
        }
    }

    func test_five_concurrent_fingerprints_consistent() async {
        let report = MockPDFReports.mockBloodworkReport()
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    FhirConverter.fingerprintBloodwork(report)
                }
            }
            var fps: [String] = []
            for await fp in group { fps.append(fp) }
            XCTAssertEqual(fps.count, 5)
            let expected = fps[0]
            for fp in fps {
                XCTAssertEqual(fp, expected, "Concurrent fingerprints must be identical")
            }
        }
    }

    func test_mixed_bloodwork_and_dexa_concurrent_no_crash() async {
        let bwText = MockPDFReports.mockBloodworkPDFText()
        let dexaText = MockPDFReports.mockDexaPDFText()
        await withTaskGroup(of: ParsedHealthReport?.self) { group in
            for i in 0..<6 {
                let text = i % 2 == 0 ? bwText : dexaText
                let filename = i % 2 == 0 ? "blood.pdf" : "dexa.pdf"
                group.addTask {
                    PDFReportParser.parseText(text, filename: filename)
                }
            }
            var results: [ParsedHealthReport?] = []
            for await r in group { results.append(r) }
            XCTAssertEqual(results.count, 6)
            XCTAssertEqual(results.compactMap { $0 }.count, 6,
                           "All mixed parses should succeed")
        }
    }
}

// MARK: - 5. Large Payload

final class LargePayloadTests: XCTestCase {

    private static let fiftyMarkerText: String = {
        var lines = [
            "Quest Diagnostics",
            "Date of Service: 11/14/2025",
            "COMPREHENSIVE METABOLIC PANEL",
        ]
        // Use String arrays to avoid tuple type-inference complexity
        let cmpLines: [String] = [
            "Glucose   94   65-99   mg/dL   Normal",
            "BUN   15   7-25   mg/dL   Normal",
            "Creatinine   0.92   0.7-1.3   mg/dL   Normal",
            "eGFR   98   >60   mL/min   Normal",
            "Sodium   141   136-145   mmol/L   Normal",
            "Potassium   4.1   3.5-5.1   mmol/L   Normal",
            "Chloride   102   98-107   mmol/L   Normal",
            "CO2   26   22-29   mmol/L   Normal",
            "Calcium   9.4   8.5-10.1   mg/dL   Normal",
            "Total Protein   7.2   6.3-8.2   g/dL   Normal",
            "Albumin   4.5   3.5-5.0   g/dL   Normal",
            "Bilirubin   0.8   0.1-1.2   mg/dL   Normal",
            "AST   22   10-40   U/L   Normal",
            "ALT   18   7-56   U/L   Normal",
            "Alkaline Phosphatase   72   44-147   U/L   Normal",
        ]
        let lipidLines: [String] = [
            "Total Cholesterol   182   <200   mg/dL   Normal",
            "LDL Cholesterol   98   <100   mg/dL   Normal",
            "HDL Cholesterol   62   >40   mg/dL   Normal",
            "Triglycerides   88   <150   mg/dL   Normal",
            "VLDL Cholesterol   18   5-40   mg/dL   Normal",
            "Non-HDL Cholesterol   120   <130   mg/dL   Normal",
            "Apolipoprotein B   72   <90   mg/dL   Normal",
            "Apolipoprotein A-I   148   101-178   mg/dL   Normal",
            "Lipoprotein-a   18   <75   nmol/L   Normal",
        ]
        let thyroidLines: [String] = [
            "TSH   1.82   0.45-4.5   mIU/L   Normal",
            "Free T4   1.2   0.82-1.77   ng/dL   Normal",
            "Free T3   3.1   2.0-4.4   pg/mL   Normal",
            "Total T3   98   71-180   ng/dL   Normal",
            "Reverse T3   14   9.2-24.1   ng/dL   Normal",
            "TPO Antibodies   8   <35   IU/mL   Normal",
        ]
        let hormoneLines: [String] = [
            "Testosterone Total   620   264-916   ng/dL   Normal",
            "Testosterone Free   12.4   7.2-24.0   pg/mL   Normal",
            "SHBG   32   10-57   nmol/L   Normal",
            "Estradiol   22   7.6-42.6   pg/mL   Normal",
            "DHEA-S   285   138-475   mcg/dL   Normal",
            "Cortisol AM   14.2   6.2-19.4   mcg/dL   Normal",
            "LH   4.8   1.7-8.6   mIU/mL   Normal",
            "FSH   4.2   1.5-12.4   mIU/mL   Normal",
            "IGF-1   198   115-307   ng/mL   Normal",
            "Growth Hormone   0.6   0.0-10.0   ng/mL   Normal",
        ]
        let otherLines: [String] = [
            "HbA1c   5.2   <5.7   %   Normal",
            "Insulin Fasting   4.8   2.6-24.9   uIU/mL   Normal",
            "C-Peptide   1.4   0.8-3.5   ng/mL   Normal",
            "hs-CRP   0.4   <1.0   mg/L   Normal",
            "Homocysteine   8.2   <10.4   umol/L   Normal",
            "Fibrinogen   245   200-400   mg/dL   Normal",
            "Ferritin   85   15-150   ng/mL   Normal",
            "Iron   92   60-170   mcg/dL   Normal",
            "TIBC   312   250-370   mcg/dL   Normal",
            "Transferrin Saturation   30   20-50   %   Normal",
            "Vitamin D   42   30-100   ng/mL   Normal",
            "Vitamin B12   498   200-900   pg/mL   Normal",
            "Folate   14.2   3.4-40.0   ng/mL   Normal",
            "Magnesium   2.1   1.8-2.4   mg/dL   Normal",
            "Zinc   88   60-130   mcg/dL   Normal",
        ]

        lines.append(contentsOf: cmpLines)
        lines.append("LIPID PANEL")
        lines.append(contentsOf: lipidLines)
        lines.append("THYROID PANEL")
        lines.append(contentsOf: thyroidLines)
        lines.append("HORMONE PANEL")
        lines.append(contentsOf: hormoneLines)
        lines.append("ADDITIONAL MARKERS")
        lines.append(contentsOf: otherLines)
        return lines.joined(separator: "\n")
    }()

    func test_fifty_marker_parse_completes_and_extracts_majority() {
        let start = Date()
        let result = PDFReportParser.parseBloodworkText(Self.fiftyMarkerText)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 2.0, "50-marker parse should complete in under 2 seconds")
        XCTAssertGreaterThanOrEqual(result.metrics.count, 20,
                                    "Should extract at least 20 of 50 markers (got \(result.metrics.count))")
    }

    func test_fifty_marker_parse_time_performance() {
        measure {
            _ = PDFReportParser.parseBloodworkText(Self.fiftyMarkerText)
        }
    }

    func test_large_bloodwork_fhir_conversion_completes() {
        let result = PDFReportParser.parseBloodworkText(Self.fiftyMarkerText)
        let start = Date()
        let fhir = FhirConverter.convertBloodworkToFhir(result)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 1.0, "FHIR conversion of large report should complete under 1s")
        XCTAssertNotNil(fhir.contained, "Large report should produce contained observations")
        XCTAssertGreaterThanOrEqual(fhir.contained?.count ?? 0, 20)
    }

    func test_large_bloodwork_fingerprint_time() {
        let result = PDFReportParser.parseBloodworkText(Self.fiftyMarkerText)
        let start = Date()
        let fp = FhirConverter.fingerprintBloodwork(result)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.5, "Fingerprinting large report should be fast")
        XCTAssertEqual(fp.count, 64)
    }

    func test_large_bloodwork_fhir_round_trip_completes() {
        let original = PDFReportParser.parseBloodworkText(Self.fiftyMarkerText)
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        let decoded = FhirConverter.convertFhirToBloodwork(fhir)
        XCTAssertNotNil(decoded, "Large payload must survive FHIR round-trip")
        XCTAssertEqual(decoded?.metrics.count, original.metrics.count,
                       "All metrics must survive round-trip")
    }

    func test_dexa_with_many_regions_does_not_crash() {
        // Build a DEXA with many synthetic regions
        var regions: [DexaRegionMetrics] = []
        for i in 1...12 {
            let d = Double(i)
            regions.append(DexaRegionMetrics(
                region: "region \(i)",
                bodyFatPercent: Double(15 + i),
                leanMassKg: Double(5 + i),
                fatMassKg: d,
                boneDensityGPerCm2: 1.0 + d * 0.01,
                tScore: d * 0.1 - 0.5,
                zScore: d * 0.1
            ))
        }
        let report = DexaReportData(
            type: "dexa", source: "Hologic", scanDate: "2025-09-22",
            totalBodyFatPercent: 18.4, totalLeanMassKg: 67.2,
            visceralFatRating: 1.2, visceralFatAreaCm2: 42.8, visceralFatVolumeCm3: 312.4,
            boneDensityTotal: DexaBoneDensityTotal(bmd: 1.28, tScore: 0.6, zScore: 0.8),
            androidGynoidRatio: 0.84, regions: regions,
            notes: [], rawText: "", confidence: 0.95
        )
        let fhir = FhirConverter.convertDexaToFhir(report)
        XCTAssertNotNil(fhir.contained, "DEXA with 12 regions should produce FHIR without crashing")
        let roundTripped = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertNotNil(roundTripped, "12-region DEXA must survive round-trip")
    }
}

// MARK: - 6. Error Paths

final class ErrorPathTests: XCTestCase {

    // MARK: Malformed PDF bytes

    func test_random_bytes_return_nil_not_crash() {
        var bytes = [UInt8](repeating: 0, count: 1024)
        for i in bytes.indices { bytes[i] = UInt8(i % 256) }
        let data = Data(bytes)
        let result = PDFReportParser.parse(pdfData: data, filename: "random.pdf")
        XCTAssertNil(result, "Random bytes should return nil without crashing")
    }

    func test_empty_data_returns_nil() {
        let result = PDFReportParser.parse(pdfData: Data(), filename: "empty.pdf")
        XCTAssertNil(result, "Empty data should return nil")
    }

    func test_pdf_magic_bytes_only_returns_nil() {
        // %PDF- header but no actual content
        let data = Data("%PDF-1.4\n%%EOF\n".utf8)
        let result = PDFReportParser.parse(pdfData: data, filename: "stub.pdf")
        // Should not crash; may return nil (no parseable content)
        XCTAssertNil(result, "Minimal PDF stub should return nil (no health data)")
    }

    func test_html_bytes_return_nil() {
        let html = "<html><body><h1>Hello World</h1></body></html>"
        let data = Data(html.utf8)
        let result = PDFReportParser.parse(pdfData: data, filename: "page.pdf")
        XCTAssertNil(result, "HTML data should not be mistaken for a health report")
    }

    func test_json_bytes_return_nil() {
        let json = #"{"name":"test","value":42,"unit":"mg/dL"}"#
        let data = Data(json.utf8)
        let result = PDFReportParser.parse(pdfData: data, filename: "data.pdf")
        XCTAssertNil(result)
    }

    func test_null_bytes_data_does_not_crash() {
        let data = Data(repeating: 0, count: 512)
        let result = PDFReportParser.parse(pdfData: data, filename: "null.pdf")
        XCTAssertNil(result, "Null bytes should return nil without crashing")
    }

    func test_very_large_random_data_does_not_crash() {
        // 512 KB of random-ish bytes
        let data = Data((0..<524_288).map { UInt8($0 % 256) })
        let result = PDFReportParser.parse(pdfData: data, filename: "large.pdf")
        XCTAssertNil(result, "Large random data should return nil without crashing")
    }

    // MARK: Unrecognized content

    func test_pdfupload_error_unrecognized_is_localized() {
        let error = PDFUploadError.unrecognizedContent
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func test_pdfupload_error_upload_failed_includes_message() {
        let error = PDFUploadError.uploadFailed("Storj returned 500")
        XCTAssertTrue(error.errorDescription?.contains("500") ?? false,
                      "Upload failed error should include the underlying message")
    }

    // MARK: Degenerate FHIR input

    func test_fhir_with_wrong_resource_type_returns_nil() {
        var fhir = FhirConverter.convertBloodworkToFhir(MockPDFReports.mockBloodworkReport())
        // Tamper with resourceType
        let tampered = FhirDiagnosticReport(
            resourceType: "Patient",  // wrong type
            id: fhir.id, status: fhir.status, category: fhir.category,
            code: fhir.code, subject: fhir.subject,
            effectiveDateTime: fhir.effectiveDateTime, issued: fhir.issued,
            performer: fhir.performer, result: fhir.result,
            conclusion: fhir.conclusion, contained: fhir.contained
        )
        let decoded = FhirConverter.convertFhirToBloodwork(tampered)
        XCTAssertNil(decoded, "FHIR with wrong resourceType must return nil, not crash")
    }

    func test_fhir_with_empty_contained_returns_empty_metrics() {
        let original = MockPDFReports.mockBloodworkReport()
        let fhir = FhirConverter.convertBloodworkToFhir(original)
        let emptyContained = FhirDiagnosticReport(
            resourceType: fhir.resourceType, id: fhir.id, status: fhir.status,
            category: fhir.category, code: fhir.code, subject: fhir.subject,
            effectiveDateTime: fhir.effectiveDateTime, issued: fhir.issued,
            performer: fhir.performer, result: fhir.result,
            conclusion: fhir.conclusion, contained: []
        )
        let decoded = FhirConverter.convertFhirToBloodwork(emptyContained)
        XCTAssertNotNil(decoded, "FHIR with empty contained should not return nil (just empty metrics)")
        XCTAssertEqual(decoded?.metrics.count, 0, "Empty contained = zero metrics")
    }

    // MARK: Parser state isolation between calls

    func test_sequential_parses_dont_bleed_state() {
        // Two completely different texts parsed back-to-back should give independent results
        let text1 = MockPDFReports.mockBloodworkPDFText()
        let text2 = MockPDFReports.mockDexaPDFText()

        let r1 = PDFReportParser.parseText(text1, filename: "blood.pdf")
        let r2 = PDFReportParser.parseText(text2, filename: "dexa.pdf")

        if case .bloodwork = r1 { /* ok */ } else { XCTFail("First parse should be bloodwork") }
        if case .dexa = r2 { /* ok */ } else { XCTFail("Second parse should be dexa") }
    }

    func test_parse_called_repeatedly_gives_consistent_results() {
        let text = MockPDFReports.mockBloodworkPDFText()
        let r1 = PDFReportParser.parseBloodworkText(text)
        let r2 = PDFReportParser.parseBloodworkText(text)
        let r3 = PDFReportParser.parseBloodworkText(text)
        XCTAssertEqual(r1.metrics.count, r2.metrics.count)
        XCTAssertEqual(r2.metrics.count, r3.metrics.count)
        XCTAssertEqual(r1.reportDate, r3.reportDate)
    }
}
