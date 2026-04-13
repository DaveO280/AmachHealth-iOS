// PDFReportModels.swift
// AmachHealth
//
// Swift models matching /src/types/reportData.ts on the website.
// These types feed into FhirConverter → Storj upload (dataType: bloodwork-report-fhir / dexa-report-fhir).
// Field names, optionality, and value semantics must stay in sync with the TypeScript originals.

import Foundation

// MARK: - Bloodwork

typealias BloodworkFlag = String   // "low" | "high" | "critical-low" | "critical-high" | "normal"

struct BloodworkMetric: Codable, Equatable {
    let name: String
    let value: Double?
    let valueText: String?
    let unit: String?
    let referenceRange: String?
    let panel: String?
    let collectedAt: String?       // ISO-8601 string (matches web field)
    let flag: BloodworkFlag?
    let interpretationNotes: [String]?
}

struct BloodworkReportData: Codable, Equatable {
    let type: String               // always "bloodwork"
    let source: String?
    let reportDate: String?        // ISO date string e.g. "2025-11-14"
    let laboratory: String?
    let panels: [String: [BloodworkMetric]]
    let metrics: [BloodworkMetric]
    let notes: [String]?
    let rawText: String
    let confidence: Double         // 0.0 – 1.0
}

// MARK: - DEXA

struct DexaRegionMetrics: Codable, Equatable {
    let region: String
    let bodyFatPercent: Double?
    let leanMassKg: Double?
    let fatMassKg: Double?
    let boneDensityGPerCm2: Double?
    let tScore: Double?
    let zScore: Double?
}

struct DexaBoneDensityTotal: Codable, Equatable {
    let bmd: Double?
    let tScore: Double?
    let zScore: Double?
}

struct DexaReportData: Codable, Equatable {
    let type: String               // always "dexa"
    let source: String?
    let scanDate: String?          // ISO date string e.g. "2025-09-22"
    let totalBodyFatPercent: Double?
    let totalLeanMassKg: Double?
    let visceralFatRating: Double?
    let visceralFatAreaCm2: Double?
    let visceralFatVolumeCm3: Double?
    let boneDensityTotal: DexaBoneDensityTotal?
    let androidGynoidRatio: Double?
    let regions: [DexaRegionMetrics]
    let notes: [String]?
    let rawText: String
    let confidence: Double         // 0.0 – 1.0
}

// MARK: - Medical Record (generic catch-all)

struct MedicalRecordData: Codable, Equatable {
    let type: String               // always "medical-record"
    let source: String?
    let reportDate: String?        // ISO date string
    let documentType: String?      // "imaging", "discharge-summary", "prescription", "lab-panel", "other"
    let title: String?
    let summary: String?           // AI-generated summary
    let keyFindings: [String]?
    let medications: [String]?
    let diagnoses: [String]?
    let rawText: String
    let confidence: Double         // 0.0 – 1.0
}

// MARK: - Union

enum ParsedHealthReport {
    case bloodwork(BloodworkReportData)
    case dexa(DexaReportData)
    case medicalRecord(MedicalRecordData)

    var reportType: String {
        switch self {
        case .bloodwork: return "bloodwork"
        case .dexa: return "dexa"
        case .medicalRecord: return "medical-record"
        }
    }
}

// MARK: - FHIR DiagnosticReport (stored on Storj; matches website's dexaToFhir.ts types)

struct FhirCoding: Codable {
    let system: String
    let code: String
    let display: String
}

struct FhirCodeableConcept: Codable {
    let coding: [FhirCoding]
}

struct FhirReference: Codable {
    let reference: String?
}

struct FhirQuantity: Codable {
    let value: Double
    let unit: String
    let system: String?
    let code: String?
}

struct FhirInterpretationEntry: Codable {
    let coding: [FhirCoding]
}

struct FhirObservationComponent: Codable {
    let code: FhirCodeableConcept
    let valueQuantity: FhirQuantity?
}

struct FhirObservation: Codable {
    let resourceType: String          // "Observation"
    let id: String?
    let status: String                // "final"
    let category: [FhirCodeableConcept]?
    let code: FhirCodeableConcept
    let subject: FhirReference?
    let effectiveDateTime: String?
    let valueQuantity: FhirQuantity?
    let valueString: String?
    let component: [FhirObservationComponent]?
    let interpretation: [FhirInterpretationEntry]?
    let referenceRange: [FhirReferenceRange]?
}

struct FhirReferenceRange: Codable {
    let text: String?
}

struct FhirDiagnosticReport: Codable {
    let resourceType: String          // "DiagnosticReport"
    let id: String?
    let status: String                // "final"
    let category: [FhirCodeableConcept]?
    let code: FhirCodeableConcept
    let subject: FhirReference?
    let effectiveDateTime: String?
    let issued: String?
    let performer: [FhirReference]?
    let result: [FhirReference]?
    let conclusion: String?
    let contained: [FhirObservation]?
}

// MARK: - Upload result

struct PDFUploadResult {
    let storjUri: String
    let contentHash: String
    let reportId: String
    let report: ParsedHealthReport
    let wasDuplicate: Bool
}
