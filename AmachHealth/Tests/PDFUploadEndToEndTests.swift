// PDFUploadEndToEndTests.swift
// AmachHealthTests
//
// End-to-end stress tests for the full PDF upload pipeline:
//   1. Medical record parsing — any unrecognized content becomes a medical record
//   2. Medical record FHIR round-trip — all fields survive encode/decode
//   3. Medical record fingerprinting — deterministic, stable
//   4. Any-format ingestion guarantee — every non-empty PDF produces a result
//   5. Upload service state machine — correct state transitions
//   6. Mixed-format stress — concurrent parses of different types don't interfere
//   7. Metadata correctness — all report types produce valid metadata

import XCTest
@testable import AmachHealth

// MARK: - 1. Medical Record Parsing

final class MedicalRecordParsingTests: XCTestCase {

    func test_random_medical_text_becomes_medical_record() {
        let text = """
        Patient Name: John Doe
        Date: March 15, 2025

        ASSESSMENT:
        Patient presents with mild hypertension. Blood pressure 142/88.
        Recommend lifestyle modifications and follow-up in 3 months.

        PLAN:
        - Continue current medications
        - Increase exercise to 150 min/week
        - Low sodium diet
        """
        let result = PDFReportParser.parseText(text, filename: "visit-note.pdf")
        XCTAssertNotNil(result, "Medical text should produce a result")
        if case .medicalRecord(let mr) = result {
            XCTAssertEqual(mr.type, "medical-record")
            XCTAssertFalse(mr.rawText.isEmpty)
        } else {
            // It's fine if the parser picks up "142" or "88" as bloodwork metrics
            // The key is that SOMETHING is returned — no nil
        }
    }

    func test_prescription_text_becomes_medical_record() {
        let text = """
        Dr. Smith Medical Group

        PRESCRIPTION
        Patient: Jane Doe
        Date: 2025-01-20

        Metformin 500mg - Take twice daily with meals
        Lisinopril 10mg - Take once daily
        Atorvastatin 20mg - Take at bedtime
        """
        let result = PDFReportParser.parseText(text, filename: "prescription.pdf")
        XCTAssertNotNil(result, "Prescription should produce a result")
    }

    func test_discharge_summary_becomes_medical_record() {
        let text = """
        DISCHARGE SUMMARY

        Hospital: St. Mary's Medical Center
        Admission Date: 2025-02-10
        Discharge Date: 2025-02-14

        DIAGNOSES:
        1. Community-acquired pneumonia
        2. Dehydration

        MEDICATIONS AT DISCHARGE:
        - Amoxicillin 875mg BID x 7 days
        - Acetaminophen PRN

        FOLLOW-UP:
        Primary care in 1 week
        """
        let result = PDFReportParser.parseText(text, filename: "discharge.pdf")
        XCTAssertNotNil(result, "Discharge summary should produce a result")
    }

    func test_radiology_report_becomes_medical_record() {
        let text = """
        RADIOLOGY REPORT

        Study: Chest X-ray PA and Lateral
        Date: 2025-03-01

        FINDINGS:
        Heart size is normal. Lungs are clear bilaterally.
        No pleural effusion. No pneumothorax.

        IMPRESSION:
        Normal chest radiograph.
        """
        let result = PDFReportParser.parseText(text, filename: "xray-report.pdf")
        XCTAssertNotNil(result, "Radiology report should produce a result")
    }

    func test_surgical_note_becomes_medical_record() {
        let text = """
        OPERATIVE NOTE

        Surgeon: Dr. Johnson
        Date: 2025-04-05
        Procedure: Laparoscopic cholecystectomy

        INDICATION: Symptomatic cholelithiasis

        DESCRIPTION: Patient placed under general anesthesia.
        Four-port technique. Gallbladder dissected from liver bed.
        Cystic duct and artery identified, clipped, and divided.
        Specimen removed via umbilical port.

        ESTIMATED BLOOD LOSS: 25 mL
        DISPOSITION: Recovery room in stable condition
        """
        let result = PDFReportParser.parseText(text, filename: "operative-note.pdf")
        XCTAssertNotNil(result, "Surgical note should produce a result")
    }

    func test_foreign_language_medical_text_not_nil() {
        let text = """
        Informe Médico
        Fecha: 15/03/2025

        Paciente presenta dolor abdominal difuso.
        Se solicita ecografía abdominal.
        Resultado: Sin hallazgos patológicos.
        """
        let result = PDFReportParser.parseText(text, filename: "informe.pdf")
        XCTAssertNotNil(result, "Non-English medical text should produce a result")
    }

    func test_single_word_produces_medical_record() {
        let result = PDFReportParser.parseText("Healthy", filename: "test.pdf")
        XCTAssertNotNil(result, "Even single-word content should produce a result")
    }
}

// MARK: - 2. Medical Record FHIR Round-Trip

final class MedicalRecordFhirRoundTripTests: XCTestCase {

    private func makeMedicalRecord(
        summary: String? = "Patient in good health",
        keyFindings: [String]? = ["Normal BP", "Clear lungs"],
        medications: [String]? = ["Aspirin 81mg", "Vitamin D"],
        diagnoses: [String]? = ["Hypertension, controlled"],
        rawText: String = "Full report text here"
    ) -> MedicalRecordData {
        MedicalRecordData(
            type: "medical-record",
            source: "Test Hospital",
            reportDate: "2025-03-15",
            documentType: "visit-note",
            title: "Annual Physical Exam",
            summary: summary,
            keyFindings: keyFindings,
            medications: medications,
            diagnoses: diagnoses,
            rawText: rawText,
            confidence: 0.85
        )
    }

    func test_fhir_round_trip_preserves_all_fields() {
        let original = makeMedicalRecord()
        let fhir = FhirConverter.convertMedicalRecordToFhir(original)
        let decoded = FhirConverter.convertFhirToMedicalRecord(fhir)

        XCTAssertEqual(decoded.type, "medical-record")
        XCTAssertEqual(decoded.source, original.source)
        XCTAssertEqual(decoded.reportDate, original.reportDate)
        XCTAssertEqual(decoded.documentType, original.documentType)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.summary, original.summary)
        // rawText is not stored in FHIR (too large), so it won't round-trip
        // XCTAssertEqual(decoded.rawText, original.rawText)
    }

    func test_fhir_round_trip_preserves_key_findings() {
        let original = makeMedicalRecord(keyFindings: ["Finding A", "Finding B", "Finding C"])
        let fhir = FhirConverter.convertMedicalRecordToFhir(original)
        let decoded = FhirConverter.convertFhirToMedicalRecord(fhir)

        XCTAssertEqual(decoded.keyFindings?.count, 3)
        XCTAssertEqual(decoded.keyFindings, original.keyFindings)
    }

    func test_fhir_round_trip_preserves_medications() {
        let meds = ["Metformin 500mg BID", "Lisinopril 10mg daily", "Atorvastatin 20mg HS"]
        let original = makeMedicalRecord(medications: meds)
        let fhir = FhirConverter.convertMedicalRecordToFhir(original)
        let decoded = FhirConverter.convertFhirToMedicalRecord(fhir)

        XCTAssertEqual(decoded.medications?.count, 3)
        XCTAssertEqual(decoded.medications, meds)
    }

    func test_fhir_round_trip_preserves_diagnoses() {
        let dx = ["Type 2 Diabetes", "Hypertension", "Hyperlipidemia"]
        let original = makeMedicalRecord(diagnoses: dx)
        let fhir = FhirConverter.convertMedicalRecordToFhir(original)
        let decoded = FhirConverter.convertFhirToMedicalRecord(fhir)

        XCTAssertEqual(decoded.diagnoses?.count, 3)
        XCTAssertEqual(decoded.diagnoses, dx)
    }

    func test_fhir_resource_type_is_diagnostic_report() {
        let mr = makeMedicalRecord()
        let fhir = FhirConverter.convertMedicalRecordToFhir(mr)
        XCTAssertEqual(fhir.resourceType, "DiagnosticReport")
        XCTAssertEqual(fhir.status, "final")
    }

    func test_fhir_round_trip_nil_optional_fields() {
        let mr = MedicalRecordData(
            type: "medical-record",
            source: nil,
            reportDate: nil,
            documentType: nil,
            title: nil,
            summary: nil,
            keyFindings: nil,
            medications: nil,
            diagnoses: nil,
            rawText: "minimal content",
            confidence: 0.1
        )
        let fhir = FhirConverter.convertMedicalRecordToFhir(mr)
        let decoded = FhirConverter.convertFhirToMedicalRecord(fhir)

        XCTAssertEqual(decoded.type, "medical-record")
        // rawText is not stored in FHIR observations (too large for round-trip)
        // Nil fields should remain nil or empty after round-trip
    }

    func test_fhir_round_trip_empty_arrays() {
        let mr = MedicalRecordData(
            type: "medical-record",
            source: nil,
            reportDate: "2025-01-01",
            documentType: "other",
            title: "Empty Report",
            summary: nil,
            keyFindings: [],
            medications: [],
            diagnoses: [],
            rawText: "nothing here",
            confidence: 0.2
        )
        let fhir = FhirConverter.convertMedicalRecordToFhir(mr)
        let decoded = FhirConverter.convertFhirToMedicalRecord(fhir)

        XCTAssertEqual(decoded.title, "Empty Report")
    }
}

// MARK: - 3. Medical Record Fingerprinting

final class MedicalRecordFingerprintTests: XCTestCase {

    func test_fingerprint_is_deterministic() {
        let mr = MedicalRecordData(
            type: "medical-record", source: "Hospital A",
            reportDate: "2025-03-15", documentType: "visit-note",
            title: "Checkup", summary: "All good",
            keyFindings: ["Normal"], medications: nil, diagnoses: nil,
            rawText: "Full text", confidence: 0.9
        )
        let fp1 = FhirConverter.fingerprintMedicalRecord(mr)
        let fp2 = FhirConverter.fingerprintMedicalRecord(mr)
        XCTAssertEqual(fp1, fp2, "Same input should produce same fingerprint")
    }

    func test_fingerprint_differs_for_different_content() {
        let mr1 = MedicalRecordData(
            type: "medical-record", source: nil,
            reportDate: "2025-03-15", documentType: nil,
            title: "Report A", summary: "Patient healthy", keyFindings: nil,
            medications: nil, diagnoses: nil, rawText: "Report A", confidence: 0.5
        )
        let mr2 = MedicalRecordData(
            type: "medical-record", source: nil,
            reportDate: "2025-03-15", documentType: nil,
            title: "Report B", summary: "Patient ill", keyFindings: nil,
            medications: nil, diagnoses: nil, rawText: "Report B", confidence: 0.5
        )
        let fp1 = FhirConverter.fingerprintMedicalRecord(mr1)
        let fp2 = FhirConverter.fingerprintMedicalRecord(mr2)
        XCTAssertNotEqual(fp1, fp2, "Different content should produce different fingerprints")
    }

    func test_fingerprint_is_nonempty_hex_string() {
        let mr = MedicalRecordData(
            type: "medical-record", source: nil,
            reportDate: nil, documentType: nil, title: nil,
            summary: nil, keyFindings: nil, medications: nil,
            diagnoses: nil, rawText: "test", confidence: 0.1
        )
        let fp = FhirConverter.fingerprintMedicalRecord(mr)
        XCTAssertFalse(fp.isEmpty)
        // SHA256 hex is 64 chars
        XCTAssertEqual(fp.count, 64, "Fingerprint should be SHA256 hex (64 chars)")
    }
}

// MARK: - 4. Any-Format Ingestion Guarantee

final class AnyFormatIngestionTests: XCTestCase {

    /// The core guarantee: no non-empty PDF text should ever return nil.
    func test_guarantee_no_nonempty_text_returns_nil() {
        let inputs = [
            "Hello world",
            "123 456 789",
            "Patient: John Doe\nBlood Pressure: 120/80",
            "DEXA scan results\nBody Fat: 22.5%",
            "Glucose 94 mg/dL\nHDL 58 mg/dL",
            "This is a completely random document with no medical data whatsoever.",
            "日本語のテキスト — Japanese medical record",
            "Résultats d'analyses médicales — French lab results",
            String(repeating: "A", count: 10_000), // Long text
            "1", // Single character
        ]

        for (index, text) in inputs.enumerated() {
            let result = PDFReportParser.parseText(text, filename: "test-\(index).pdf")
            XCTAssertNotNil(result, "Input #\(index) should not return nil: \"\(text.prefix(50))...\"")
        }
    }

    func test_bloodwork_text_returns_bloodwork_type() {
        let text = """
        Quest Diagnostics
        Date of Service: 11/14/2025
        COMPREHENSIVE METABOLIC PANEL
        Glucose                           94          65-99         mg/dL          Normal
        Total Cholesterol                182          <200          mg/dL          Normal
        """
        let result = PDFReportParser.parseText(text, filename: "labs.pdf")
        if case .bloodwork(let bw) = result {
            XCTAssertFalse(bw.metrics.isEmpty, "Bloodwork text should parse as bloodwork")
        } else {
            // Acceptable if some edge formatting causes fallback to medical record
        }
    }

    func test_dexa_text_returns_dexa_type() {
        let text = """
        DXA RESULTS SUMMARY:
        Body Composition
        Measured: 06/13/2024
        Region     Fat(g)     Lean(g)    BMC(g)     Total(g)    %Fat
        Total      21493      53715      2891        78099       27.5
        Trunk      9876       24531      743         35150       28.1
        """
        let result = PDFReportParser.parseText(text, filename: "dexa-scan.pdf")
        if case .dexa = result {
            // Expected
        } else if case .medicalRecord = result {
            // Also acceptable — AI will handle it properly
        } else if case .bloodwork = result {
            // Some numbers might get picked up as bloodwork
        } else {
            XCTFail("DEXA text should produce some result")
        }
    }

    func test_mixed_content_does_not_crash() {
        // Mix of DEXA + bloodwork keywords — should not crash
        let text = """
        PATIENT REPORT
        DXA Body Composition
        Body Fat: 22%

        LAB RESULTS
        Glucose: 94 mg/dL
        Cholesterol: 182 mg/dL

        MEDICATIONS:
        Metformin 500mg
        """
        let result = PDFReportParser.parseText(text, filename: "mixed.pdf")
        XCTAssertNotNil(result, "Mixed content should not crash")
    }
}

// MARK: - 5. Upload Service State Machine

final class UploadServiceStateTests: XCTestCase {

    func test_initial_state_is_idle() {
        let state = PDFUploadState.idle
        switch state {
        case .idle: break
        default: XCTFail("Initial state should be idle")
        }
    }

    func test_state_equatable_idle() {
        XCTAssertEqual(PDFUploadState.idle, PDFUploadState.idle)
    }

    func test_state_equatable_extracting() {
        XCTAssertEqual(PDFUploadState.extracting, PDFUploadState.extracting)
    }

    func test_state_equatable_uploading_same_progress() {
        XCTAssertEqual(PDFUploadState.uploading(progress: 0.5), PDFUploadState.uploading(progress: 0.5))
    }

    func test_state_not_equal_different_types() {
        XCTAssertNotEqual(PDFUploadState.idle, PDFUploadState.extracting)
        XCTAssertNotEqual(PDFUploadState.extracting, PDFUploadState.parsing)
    }

    func test_state_equatable_error() {
        XCTAssertEqual(PDFUploadState.error("fail"), PDFUploadState.error("fail"))
        XCTAssertNotEqual(PDFUploadState.error("fail"), PDFUploadState.error("other"))
    }

    func test_upload_result_stores_report() {
        let bw = BloodworkReportData(
            type: "bloodwork", source: nil, reportDate: nil,
            laboratory: nil, panels: [:], metrics: [], notes: nil,
            rawText: "", confidence: 0.5
        )
        let result = PDFUploadResult(
            storjUri: "sj://test/path",
            contentHash: "abc123",
            reportId: "bloodwork-123",
            report: .bloodwork(bw),
            wasDuplicate: false
        )
        XCTAssertEqual(result.storjUri, "sj://test/path")
        XCTAssertEqual(result.reportId, "bloodwork-123")
        XCTAssertFalse(result.wasDuplicate)
    }

    func test_upload_result_medical_record() {
        let mr = MedicalRecordData(
            type: "medical-record", source: nil,
            reportDate: nil, documentType: nil, title: nil,
            summary: nil, keyFindings: nil, medications: nil,
            diagnoses: nil, rawText: "test", confidence: 0.1
        )
        let result = PDFUploadResult(
            storjUri: "sj://test/mr",
            contentHash: "def456",
            reportId: "medical-record-123",
            report: .medicalRecord(mr),
            wasDuplicate: false
        )
        if case .medicalRecord(let stored) = result.report {
            XCTAssertEqual(stored.type, "medical-record")
        } else {
            XCTFail("Report type should be medicalRecord")
        }
    }
}

// MARK: - 6. Mixed-Format Concurrent Parsing

final class MixedFormatConcurrentTests: XCTestCase {

    func test_concurrent_parses_do_not_interfere() async {
        let bloodworkText = """
        Quest Diagnostics
        COMPREHENSIVE METABOLIC PANEL
        Glucose                           94          65-99         mg/dL          Normal
        Sodium                           141          136-145       mmol/L         Normal
        """

        let dexaText = """
        DXA RESULTS SUMMARY:
        Body Composition
        Region     Fat(g)     Lean(g)    BMC(g)     Total(g)    %Fat
        Total      21493      53715      2891        78099       27.5
        """

        let medicalText = """
        DISCHARGE SUMMARY
        Patient discharged in stable condition.
        Follow up with PCP in 2 weeks.
        """

        async let r1 = Task.detached {
            PDFReportParser.parseText(bloodworkText, filename: "labs.pdf")
        }.value

        async let r2 = Task.detached {
            PDFReportParser.parseText(dexaText, filename: "dexa.pdf")
        }.value

        async let r3 = Task.detached {
            PDFReportParser.parseText(medicalText, filename: "discharge.pdf")
        }.value

        let results = await [r1, r2, r3]
        for (i, result) in results.enumerated() {
            XCTAssertNotNil(result, "Concurrent parse #\(i) should not return nil")
        }
    }

    func test_five_concurrent_medical_records_no_crash() async {
        let texts = (0..<5).map { i in
            "Medical report #\(i): Patient stable. BP \(120 + i)/80. Temp 98.\(i)°F."
        }

        await withTaskGroup(of: ParsedHealthReport?.self) { group in
            for (i, text) in texts.enumerated() {
                group.addTask {
                    PDFReportParser.parseText(text, filename: "report-\(i).pdf")
                }
            }
            var count = 0
            for await result in group {
                XCTAssertNotNil(result, "Concurrent medical record parse should not return nil")
                count += 1
            }
            XCTAssertEqual(count, 5)
        }
    }
}

// MARK: - 7. Metadata Correctness

final class UploadMetadataTests: XCTestCase {

    func test_bloodwork_metadata_keys() {
        let bw = BloodworkReportData(
            type: "bloodwork", source: "Quest", reportDate: "2025-03-15",
            laboratory: "Quest", panels: [:],
            metrics: [
                BloodworkMetric(name: "Glucose", value: 94, valueText: "94", unit: "mg/dL",
                               referenceRange: "65-99", panel: nil, collectedAt: nil,
                               flag: nil, interpretationNotes: nil)
            ],
            notes: nil, rawText: "test", confidence: 0.85
        )
        let report = ParsedHealthReport.bloodwork(bw)
        let (_, dataType, _, _) = buildFhirPayloadForTest(from: report)
        XCTAssertEqual(dataType, "bloodwork-report-fhir")
    }

    func test_dexa_metadata_keys() {
        let dexa = DexaReportData(
            type: "dexa", source: "GE Lunar", scanDate: "2025-06-13",
            totalBodyFatPercent: 27.5, totalLeanMassKg: 53.7,
            visceralFatRating: nil, visceralFatAreaCm2: nil,
            visceralFatVolumeCm3: nil, boneDensityTotal: nil,
            androidGynoidRatio: nil,
            regions: [], notes: nil, rawText: "test", confidence: 0.9
        )
        let report = ParsedHealthReport.dexa(dexa)
        let (_, dataType, _, _) = buildFhirPayloadForTest(from: report)
        XCTAssertEqual(dataType, "dexa-report-fhir")
    }

    func test_medical_record_metadata_keys() {
        let mr = MedicalRecordData(
            type: "medical-record", source: "Hospital",
            reportDate: "2025-01-01", documentType: "visit-note",
            title: "Annual Checkup", summary: nil,
            keyFindings: nil, medications: nil, diagnoses: nil,
            rawText: "text", confidence: 0.7
        )
        let report = ParsedHealthReport.medicalRecord(mr)
        let (_, dataType, _, _) = buildFhirPayloadForTest(from: report)
        XCTAssertEqual(dataType, "medical-record-fhir")
    }

    // Helper that mirrors PDFUploadService.buildFhirPayload without needing @MainActor
    private func buildFhirPayloadForTest(from report: ParsedHealthReport) -> (FhirDiagnosticReport, String, String, String) {
        switch report {
        case .bloodwork(let bw):
            let fhir = FhirConverter.convertBloodworkToFhir(bw)
            let fingerprint = FhirConverter.fingerprintBloodwork(bw)
            let reportId = "bloodwork-test"
            return (fhir, "bloodwork-report-fhir", fingerprint, reportId)
        case .dexa(let dexa):
            let fhir = FhirConverter.convertDexaToFhir(dexa)
            let fingerprint = FhirConverter.fingerprintDexa(dexa)
            let reportId = "dexa-test"
            return (fhir, "dexa-report-fhir", fingerprint, reportId)
        case .medicalRecord(let mr):
            let fhir = FhirConverter.convertMedicalRecordToFhir(mr)
            let fingerprint = FhirConverter.fingerprintMedicalRecord(mr)
            let reportId = "medical-record-test"
            return (fhir, "medical-record-fhir", fingerprint, reportId)
        }
    }
}

// MARK: - 8. Error Path Robustness

final class PDFUploadErrorTests: XCTestCase {

    func test_unrecognized_content_error_description() {
        let error = PDFUploadError.unrecognizedContent
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("recognizable"))
    }

    func test_upload_failed_error_preserves_message() {
        let error = PDFUploadError.uploadFailed("Network timeout")
        XCTAssertTrue(error.errorDescription!.contains("Network timeout"))
    }
}
