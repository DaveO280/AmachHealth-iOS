// PDFUploadService.swift
// AmachHealth
//
// Orchestrates the PDF → vault pipeline:
//   1. Extract text with PDFKit
//   2. Parse (AI first, local regex fallback) into a ParsedHealthReport
//   3. Save the report in the vault; duplicates are found by fingerprint
//   4. Keep the original PDF on the phone (lab_pdfs) so encrypted backup
//      carries it too
//
// Nothing is uploaded to Storj and the encryption key isn't used.

import Foundation

// MARK: - Upload state

enum PDFUploadState: Equatable {
    case idle
    case extracting
    case parsing
    case uploading(progress: Double)
    case done(PDFUploadResult)
    case error(String)

    static func == (lhs: PDFUploadState, rhs: PDFUploadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.extracting, .extracting), (.parsing, .parsing): return true
        case (.uploading(let a), .uploading(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        case (.done, .done): return true
        default: return false
        }
    }
}

// MARK: - Service

@MainActor
final class PDFUploadService: ObservableObject {
    @Published var state: PDFUploadState = .idle

    static let shared = PDFUploadService()
    private init() {}

    // MARK: - Public

    /// Parse a PDF and save it in the vault. Reports already in the vault
    /// (matched by fingerprint) are returned as duplicates.
    func upload(pdfData: Data, filename: String) async throws -> PDFUploadResult {
        guard let vault = LocalVault.shared.database else {
            throw PDFUploadError.uploadFailed("Connect your wallet to save reports on this phone.")
        }

        // Step 1: Extract text from PDF
        state = .extracting
        let text = await Task.detached(priority: .userInitiated) {
            PDFReportParser.extractText(from: pdfData)
        }.value

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PDFUploadError.unrecognizedContent
        }

        // Step 2: Parse — try AI first, fall back to local regex
        state = .parsing
        var report: ParsedHealthReport?

        // AI path (requires network)
        do {
            report = try await AmachAPIClient.shared.parseReportWithAI(
                text: text,
                sourceName: filename
            )
            #if DEBUG
            print("📄 [PDF] AI parsing succeeded")
            #endif
        } catch {
            #if DEBUG
            print("📄 [PDF] AI parsing failed, falling back to regex: \(error.localizedDescription)")
            #endif
        }

        // Regex fallback (offline-capable)
        if report == nil {
            report = await Task.detached(priority: .userInitiated) {
                PDFReportParser.parseText(text, filename: filename)
            }.value
        }

        guard let report else {
            throw PDFUploadError.unrecognizedContent
        }

        // Step 3: Save in the vault
        state = .uploading(progress: 0.5)
        let reportId = Self.reportId(for: report)
        let item = Self.vaultItem(for: report, id: reportId, pdfSHA256: LabVaultMapping.sha256Hex(pdfData))
        let savedId: String
        let duplicate: Bool
        switch try vault.saveLabReport(item) {
        case .duplicate(let existingId):
            savedId = existingId
            duplicate = true
        case .inserted:
            savedId = reportId
            duplicate = false
        }

        // Step 4: Keep the original PDF (backed up as its own object).
        try vault.saveLabPdf(pdfData, reportId: savedId, filename: filename)

        let result = PDFUploadResult(storjUri: "", contentHash: "", reportId: savedId,
                                     report: report, wasDuplicate: duplicate)
        state = .done(result)
        return result
    }

    func reset() { state = .idle }

    static func vaultItem(for report: ParsedHealthReport, id: String, pdfSHA256: String?) -> LabReportWithMarkers {
        switch report {
        case .bloodwork(let bw):
            return LabVaultMapping.bloodwork(bw, id: id, origin: "device", pdfSHA256: pdfSHA256)
        case .dexa(let dexa):
            return LabVaultMapping.dexa(dexa, id: id, origin: "device", pdfSHA256: pdfSHA256)
        case .medicalRecord(let mr):
            return LabVaultMapping.medical(mr, id: id, origin: "device", pdfSHA256: pdfSHA256)
        }
    }

    // MARK: - Helpers

    static func reportId(for report: ParsedHealthReport) -> String {
        switch report {
        case .bloodwork(let bw): return "bloodwork-\(bw.reportDate ?? timestampString())-\(shortRandom())"
        case .dexa(let dexa): return "dexa-\(dexa.scanDate ?? timestampString())-\(shortRandom())"
        case .medicalRecord(let mr): return "medical-record-\(mr.reportDate ?? timestampString())-\(shortRandom())"
        }
    }

    private static func timestampString() -> String {
        String(Int(Date().timeIntervalSince1970))
    }

    private static func shortRandom() -> String {
        String(Int.random(in: 100_000_000...999_999_999), radix: 36)
    }
}

// MARK: - Errors

enum PDFUploadError: LocalizedError {
    case unrecognizedContent
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unrecognizedContent:
            return "The PDF doesn't appear to contain recognizable bloodwork or DEXA data. Try a different file."
        case .uploadFailed(let msg):
            return "Upload failed: \(msg)"
        }
    }
}

// MARK: - State extraction helper

private extension PDFUploadState {
    var doneResult: PDFUploadResult? {
        if case .done(let r) = self { return r }
        return nil
    }
}

