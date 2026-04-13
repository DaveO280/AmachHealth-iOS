// MedicalRecordModels.swift
// AmachHealth
//
// Types for the Medical Records Upload V1 feature.
// Mirrors the TypeScript enums and MedicalRecordMetadata interface in the spec.
// Field names and value semantics must stay in sync with the web types.

import Foundation

// MARK: - Category

/// User-selectable category for a medical record.
/// Bloodwork and DexaScan are Lane A (structured pipeline);
/// everything else is Lane B (document-only).
enum MedicalRecordCategory: String, Codable, CaseIterable, Identifiable {
    // Lane A — Structured (existing renderers)
    case bloodwork           = "bloodwork"
    case dexaScan            = "dexa_scan"

    // Lane B — Document only (v1)
    case visitNote           = "visit_note"
    case imagingReport       = "imaging_report"
    case dischargeSummary    = "discharge_summary"
    case vaccinationRecord   = "vaccination_record"
    case prescription        = "prescription"
    case referralLetter      = "referral_letter"
    case geneticReport       = "genetic_report"
    case mentalHealthNote    = "mental_health_note"
    case dentalRecord        = "dental_record"
    case visionRecord        = "vision_record"
    case other               = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bloodwork:         return "Bloodwork"
        case .dexaScan:          return "DEXA Scan"
        case .visitNote:         return "Visit Note"
        case .imagingReport:     return "Imaging Report"
        case .dischargeSummary:  return "Discharge Summary"
        case .vaccinationRecord: return "Vaccination Record"
        case .prescription:      return "Prescription"
        case .referralLetter:    return "Referral Letter"
        case .geneticReport:     return "Genetic Report"
        case .mentalHealthNote:  return "Mental Health Note"
        case .dentalRecord:      return "Dental Record"
        case .visionRecord:      return "Vision Record"
        case .other:             return "Other"
        }
    }

    var icon: String {
        switch self {
        case .bloodwork:         return "drop.fill"
        case .dexaScan:          return "figure.stand"
        case .visitNote:         return "stethoscope"
        case .imagingReport:     return "rays"
        case .dischargeSummary:  return "house.and.flag.fill"
        case .vaccinationRecord: return "syringe.fill"
        case .prescription:      return "pills.fill"
        case .referralLetter:    return "envelope.badge.shield.half.filled"
        case .geneticReport:     return "dna"
        case .mentalHealthNote:  return "brain.head.profile"
        case .dentalRecord:      return "mouth.fill"
        case .visionRecord:      return "eye.fill"
        case .other:             return "doc.text.fill"
        }
    }

    /// Derive the rendering hint from category.
    /// Bloodwork and DexaScan map to their structured hints; everything else
    /// maps to DocumentOnly. This mapping is enforced by the server; the client
    /// computes it to construct the metadata sidecar but cannot override it.
    var renderingHint: MedicalRenderingHint {
        switch self {
        case .bloodwork: return .structuredBloodwork
        case .dexaScan:  return .structuredDexa
        default:         return .documentOnly
        }
    }

    /// True for categories that require the existing structured parser pipeline.
    var isLaneA: Bool {
        self == .bloodwork || self == .dexaScan
    }
}

// MARK: - Rendering Hint

/// Derived from category server-side. Controls which renderer shows the record.
enum MedicalRenderingHint: String, Codable {
    case structuredBloodwork = "structured_bloodwork"
    case structuredDexa      = "structured_dexa"
    case documentOnly        = "document_only"
}

// MARK: - Parser Status

enum MedicalRecordParserStatus: String, Codable {
    case notApplicable = "not_applicable"   // Lane B records
    case pending       = "pending"           // Lane A, awaiting parse
    case succeeded     = "succeeded"
    case failed        = "failed"
    case skipped       = "skipped"           // user opted out / non-PDF
}

// MARK: - Metadata Sidecar (encrypted JSON stored on Storj)

/// One record per uploaded file. Stored as the encrypted data payload of a
/// Storj object with dataType "medical-record-metadata".
/// schemaVersion 1 is the only valid value for V1 uploads.
struct MedicalRecordMetadata: Codable, Identifiable {
    let id: String                              // uuid
    let storjKey: String                        // storjUri of the encrypted blob
    let fileName: String                        // original filename
    let mimeType: String                        // application/pdf, image/jpeg, etc.
    let sizeBytes: Int
    let uploadedAt: String                      // ISO 8601, server time
    let recordDate: String                      // ISO 8601 date the record is *about* (user-entered)
    let category: MedicalRecordCategory
    let renderingHint: MedicalRenderingHint     // derived from category, never set by user
    let notes: String?
    let providerName: String?
    var parserStatus: MedicalRecordParserStatus
    var parsedDataRef: String?                  // storjUri of extracted FHIR data, if any
    let schemaVersion: Int                      // always 1
}

// MARK: - Upload State

enum MedicalRecordUploadState: Equatable {
    case idle
    case uploading(progress: Double)
    case done(MedicalRecordUploadResult)
    case error(String)

    static func == (lhs: MedicalRecordUploadState, rhs: MedicalRecordUploadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.uploading(let a), .uploading(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        case (.done, .done): return true
        default: return false
        }
    }
}

struct MedicalRecordUploadResult {
    let metadata: MedicalRecordMetadata
    let metadataStorjUri: String
    let blobStorjUri: String
}

// MARK: - Accepted MIME Types

extension MedicalRecordCategory {
    static let acceptedMimeTypes: [String] = [
        "application/pdf",
        "image/jpeg",
        "image/png",
        "image/heic"
    ]
}
