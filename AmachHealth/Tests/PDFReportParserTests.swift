// PDFReportParserTests.swift
// AmachHealthTests
//
// Tests for:
//   - PDFReportParser: text extraction, bloodwork normalization, DEXA normalization
//   - FhirConverter: bloodwork ↔ FHIR round-trip, DEXA ↔ FHIR round-trip
//   - Fingerprinting: same data → same hash; different data → different hash
//   - PDF generation: PDFKit produces parseable output

import XCTest
import UIKit
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

    func test_nonsense_text_is_flagged_non_medical_record() {
        // Any non-empty text is kept as a generic medical record (no PDF is rejected),
        // but text with no medical content carries a "doesn't look medical" note.
        let report = PDFReportParser.parseText("Hello world this is not a lab report.", filename: "note.pdf")
        guard case .medicalRecord(let mr) = report else {
            return XCTFail("Expected medicalRecord, got \(String(describing: report))")
        }
        XCTAssertTrue(mr.appearsNonMedical)
        XCTAssertEqual(mr.summary, MedicalRecordData.noMedicalContentNote)
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
        XCTAssertEqual(metric?.value ?? 0, 5.2, accuracy: 0.01)
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
        XCTAssertEqual(metric?.value ?? 0, 1.82, accuracy: 0.001)
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
        // GE Lunar: Total=185.4 lbs, Fat=31.6 lbs → 31.6/185.4 × 100 ≈ 17.04 %
        XCTAssertEqual(parsed.totalBodyFatPercent ?? 0, 17.0, accuracy: 0.1)
    }

    func test_extracts_lean_mass() {
        // GE Lunar: Lean=148.7 lbs × 0.453592 ≈ 67.44 kg
        XCTAssertEqual(parsed.totalLeanMassKg ?? 0, 67.4, accuracy: 0.2)
    }

    func test_extracts_scan_date() {
        // "03/21/2025" → "2025-03-21"
        XCTAssertEqual(parsed.scanDate, "2025-03-21")
    }

    func test_extracts_bmd() {
        XCTAssertNotNil(parsed.boneDensityTotal, "Bone density total should be extracted")
        XCTAssertEqual(parsed.boneDensityTotal?.bmd ?? 0, 1.22, accuracy: 0.01)
    }

    func test_extracts_t_score() {
        XCTAssertEqual(parsed.boneDensityTotal?.tScore ?? 0, 0.4, accuracy: 0.1)
    }

    func test_extracts_z_score() {
        XCTAssertEqual(parsed.boneDensityTotal?.zScore ?? 0, 0.6, accuracy: 0.1)
    }

    func test_extracts_visceral_fat_rating() {
        // GE Lunar format does not include a visceral fat rating score
        XCTAssertNil(parsed.visceralFatRating)
    }

    func test_extracts_visceral_fat_area() {
        XCTAssertEqual(parsed.visceralFatAreaCm2 ?? 0, 45.2, accuracy: 0.1)
    }

    func test_extracts_android_gynoid_ratio() {
        // GE Lunar segmental format does not include an android/gynoid ratio
        XCTAssertNil(parsed.androidGynoidRatio)
    }

    func test_detects_source_ge_lunar() {
        XCTAssertEqual(parsed.source, "GE Lunar")
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
            $0.code.coding.first?.display.lowercased() == "glucose"
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
            $0.code.coding.first?.display.lowercased() == "glucose"
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
        // GE Lunar mock: 31.6/185.4 × 100 ≈ 17.0 %
        let expectedFat = report.totalBodyFatPercent ?? 0
        XCTAssertEqual(fatObs?.valueQuantity?.value ?? 0, expectedFat, accuracy: 0.1)
    }

    func test_round_trip_preserves_fat_percent() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.totalBodyFatPercent ?? 0, original.totalBodyFatPercent ?? 0,
                       accuracy: 0.01)
    }

    func test_round_trip_preserves_lean_mass() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.totalLeanMassKg ?? 0, original.totalLeanMassKg ?? 0,
                       accuracy: 0.01)
    }

    func test_round_trip_preserves_android_gynoid() {
        let original = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(original)
        let decoded = FhirConverter.convertFhirToDexa(fhir)
        XCTAssertEqual(decoded?.androidGynoidRatio ?? 0, original.androidGynoidRatio ?? 0,
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
        XCTAssertEqual(decoded?.boneDensityTotal?.bmd ?? 0, original.boneDensityTotal?.bmd ?? 0,
                       accuracy: 0.001)
        XCTAssertEqual(decoded?.boneDensityTotal?.tScore ?? 0, original.boneDensityTotal?.tScore ?? 0,
                       accuracy: 0.001)
    }

    func test_conclusion_mentions_source() {
        let report = MockPDFReports.mockDexaReport()
        let fhir = FhirConverter.convertDexaToFhir(report)
        let sourceName = report.source ?? ""
        XCTAssertTrue(fhir.conclusion?.contains(sourceName) ?? false,
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

// MARK: - Gut health (Tiny Health)

@MainActor
final class GutHealthReportTests: XCTestCase {

    private func report() -> GutHealthReport {
        GutHealthReport(json: [
            "provider": "Tiny Health",
            "collection_date": "2026-09-01",
            "summary": ["microbiome_score": 61, "gut_type": "Bacteroides"],
            "metrics": [
                "beneficial_microbes": ["bifidobacterium": ["value": 7.3, "unit": "%", "status": "great"]],
                "gut_barrier_inflammation": ["hexa_lps_index": ["value": 97, "unit": "", "status": "needs_support"]],
            ],
            "other_metrics": [
                ["name": "Cellulose", "value": 42, "unit": "rpkm", "status": "okay",
                 "section": "Digestive capacity - Fiber Digestion Capacity"],
                ["name": "Beneficial microbes: great", "value": 2, "section": "Beneficial microbes"],
                ["name": "No section", "value": 1],
                ["name": "No value", "value": NSNull()],
            ],
            "species": [
                ["name": "Phocaeicola dorei", "abundance_pct": 9.771, "classification": "variable"],
                ["name": "Escherichia flexneri", "abundance_pct": 7.092, "classification": "unfriendly"],
                ["name": "Holdemanella sp002299315", "abundance_pct": 4.11, "classification": "unknown"],
            ],
            "recommendations": ["Eat more fiber"],
        ])!
    }

    func test_every_value_becomes_a_marker_including_other_metrics() {
        let markers = LabVaultMapping.gutHealthMarkers(report().json, reportId: "r")
        XCTAssertEqual(markers.count, 2 + 2 + 3 + 3)
        let cellulose = markers.first { $0.name == "Cellulose" }
        XCTAssertEqual(cellulose?.panel, "digestive_capacity_fiber_digestion_capacity")
        XCTAssertEqual(cellulose?.value, 42)
        XCTAssertEqual(cellulose?.unit, "rpkm")
        XCTAssertEqual(cellulose?.flag, "okay")
        // Same snake_case form as the named section, so they group together.
        XCTAssertEqual(markers.first { $0.name.hasPrefix("Beneficial microbes:") }?.panel, "beneficial_microbes")
        XCTAssertEqual(markers.first { $0.name == "No section" }?.panel, "other")
        XCTAssertNil(markers.first { $0.name == "No value" })
        XCTAssertEqual(markers.filter { $0.panel == "species" }.map(\.flag), ["variable", "unfriendly", "unknown"])
    }

    func test_display_groups_summary_first_and_species_last() {
        let markers = LabVaultMapping.gutHealthMarkers(report().json, reportId: "r")
        let sections = GutHealthMarkerList.sections(markers)
        XCTAssertEqual(sections.first?.panel, "summary")
        XCTAssertEqual(sections.last?.panel, "species")
        XCTAssertEqual(sections.dropLast().last?.panel, "other")
        XCTAssertEqual(sections.reduce(0) { $0 + $1.rows.count }, markers.count, "every value is shown")
        XCTAssertEqual(sections.first { $0.panel == "beneficial_microbes" }?.rows.count, 2)
        XCTAssertEqual(GutHealthMarkerList.title("gut_barrier_inflammation"), "Gut barrier inflammation")
        XCTAssertEqual(GutHealthMarkerList.classificationCounts(sections.last!.rows),
                       "1 unfriendly · 1 variable · 1 unknown")
    }

    func test_saved_report_shows_markers_and_reaches_luma_as_gut_block() {
        let saved = LabVaultMapping.gutHealth(report(), id: "g1", origin: "device")
        XCTAssertEqual(saved.report.subtype, "gut-health")
        let context = LabContextService.gutHealth(saved)
        XCTAssertEqual(context.species.map(\.name).first, "Phocaeicola dorei")
        XCTAssertEqual(context.values.count + context.species.count, saved.markers.count)
        let block = HealthContextBuilder.formatGutHealth(context) ?? ""
        XCTAssertTrue(block.hasPrefix("Gut microbiome report (2026-09-01) — Tiny Health:"), block)
        XCTAssertTrue(block.contains("Needs attention: hexa lps index 97 (needs support)"), block)
        XCTAssertTrue(block.contains("Species: 3 detected"), block)
        XCTAssertTrue(block.contains("Phocaeicola dorei 9.771% (variable)"), block)
        XCTAssertTrue(block.contains("Cellulose 42 rpkm (okay)"), block)
    }

    func test_luma_gut_block_is_capped() {
        let many = (0..<600).map { i in
            LabGutHealthContext.Value(section: "section_\(i % 12)", name: "Measured value number \(i)",
                                      value: Double(i), text: nil, unit: "rpkm", status: "okay")
        }
        let species = (0..<400).map { i in
            LabGutHealthContext.Value(section: "species", name: "Genus species\(i)", value: 1 / Double(i + 1),
                                      text: nil, unit: "%", status: "unknown")
        }
        let block = HealthContextBuilder.formatGutHealth(
            LabGutHealthContext(date: nil, source: nil, values: many, species: species)) ?? ""
        XCTAssertLessThanOrEqual(block.count, HealthContextBuilder.maxGutChars + 40)
        XCTAssertTrue(block.contains("Species: 400 detected"), "species summary comes before the sections")
        XCTAssertTrue(block.contains("more not shown"))
    }

    // MARK: Classification dots

    func test_dot_colours_map_to_classifications() {
        XCTAssertEqual(SpeciesDots.Bitmap.code((0, 153, 133)), "B")
        XCTAssertEqual(SpeciesDots.Bitmap.code((240, 160, 60)), "V")
        XCTAssertEqual(SpeciesDots.Bitmap.code((220, 85, 85)), "U")
        XCTAssertEqual(SpeciesDots.Bitmap.code((214, 216, 207)), "X")
        XCTAssertNil(SpeciesDots.Bitmap.code((255, 255, 255)))
        XCTAssertNil(SpeciesDots.Bitmap.code((60, 60, 60)), "text is not a dot")
    }

    /// A species page drawn like Tiny Health's: a coloured dot, the name,
    /// the abundance. The key lists each row with its dot.
    func test_extracted_text_carries_a_key_of_the_species_dots() throws {
        let rows: [(UIColor, String, String)] = [
            (UIColor(red: 0, green: 0.6, blue: 0.52, alpha: 1), "Faecalibacterium prausnitzii_G", "1.125%"),
            (UIColor(red: 0.94, green: 0.63, blue: 0.24, alpha: 1), "Alistipes putredinis", "1.107%"),
            (UIColor(red: 0.86, green: 0.33, blue: 0.33, alpha: 1), "Escherichia coli_D", "0.627%"),
            (UIColor(red: 0.84, green: 0.85, blue: 0.81, alpha: 1), "KLE1615 sp900066985", "1.006%"),
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let pdf = renderer.pdfData { ctx in
            ctx.beginPage()
            let font: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11)]
            "Tiny Health gut report".draw(at: CGPoint(x: 30, y: 30), withAttributes: font)
            "All species".draw(at: CGPoint(x: 30, y: 60), withAttributes: font)
            for (i, row) in rows.enumerated() {
                let y = 100 + CGFloat(i) * 22
                row.0.setFill()
                UIBezierPath(ovalIn: CGRect(x: 30, y: y + 3, width: 6, height: 6)).fill()
                row.1.draw(at: CGPoint(x: 42, y: y), withAttributes: font)
                row.2.draw(at: CGPoint(x: 250, y: y), withAttributes: font)
            }
        }
        let text = PDFReportParser.extractText(from: pdf)
        let key = try XCTUnwrap(text.components(separatedBy: "\n\(SpeciesDots.heading)\n").last)
        let lines = key.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.map { String($0.prefix(1)) }, ["B", "V", "U", "X"], key)
        XCTAssertTrue(lines[0].replacingOccurrences(of: " ", with: "").contains("Faecalibacteriumprausnitzii_G"), key)
        XCTAssertTrue(lines[0].contains("1.125"), key)
    }

    /// Opt-in: TEST_RUNNER_AMACH_DOTS_PDF=<report.pdf> and
    /// TEST_RUNNER_AMACH_DOTS_OUT=<file> write the phone's extracted text
    /// (with the dot key) for a real report. Prints only counts.
    func test_real_report_dot_key() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["AMACH_DOTS_PDF"], let out = env["AMACH_DOTS_OUT"] else {
            throw XCTSkip("Set AMACH_DOTS_PDF and AMACH_DOTS_OUT")
        }
        let text = PDFReportParser.extractText(from: try Data(contentsOf: URL(fileURLWithPath: path)))
        try text.write(toFile: out, atomically: true, encoding: .utf8)
        let key = text.components(separatedBy: "\n\(SpeciesDots.heading)\n").dropFirst().first ?? ""
        let codes = Dictionary(grouping: key.split(separator: "\n"), by: { $0.prefix(1) }).mapValues(\.count)
        print("DOTS_KEY rows=\(key.split(separator: "\n").count) codes=\(codes.sorted { $0.key < $1.key })")
        XCTAssertFalse(key.isEmpty)
    }

    func test_microbiome_detection_survives_split_words() {
        XCTAssertTrue(SpeciesDots.isMicrobiomeReport("Tiny Healt\nh Lab Director\nTop 2\n0 species"))
        XCTAssertFalse(SpeciesDots.isMicrobiomeReport("Quest Diagnostics\nLipid panel"))
    }

    func test_other_reports_get_no_dot_key() {
        let text = PDFReportParser.extractText(from: MockPDFReports.mockBloodworkPDF())
        XCTAssertFalse(text.contains(SpeciesDots.heading))
    }
}
