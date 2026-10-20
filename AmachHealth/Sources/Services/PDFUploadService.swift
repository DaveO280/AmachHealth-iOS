// PDFUploadService.swift
// AmachHealth
//
// Orchestrates the PDF → vault pipeline in two steps, so nothing is saved
// until the user has seen what was read:
//
//   read():  extract text with PDFKit, then send it to the website's
//            private-AI parser (enclave models; about three minutes for a
//            long lab report). If the AI can't read it, stop and say why —
//            never fall back silently. The user can try again or use the
//            phone's offline reader instead.
//   save():  after review, save the report in the vault (duplicates found by
//            fingerprint) and keep the original PDF (lab_pdfs) for backup.
//
// Nothing is uploaded to Storj and the encryption key isn't used.

import Foundation

// MARK: - Read result

/// A report read from a PDF, waiting for the user to review it.
struct PDFReadResult {
    enum Reader: Equatable {
        /// The website's private enclave model read it.
        case privateAI(model: String?)
        /// The AI ran but couldn't map the report; the website's offline parser read it.
        case serverParser(aiProblem: String?)
        /// The phone's offline parser read it (the user chose this after the AI failed).
        case phoneParser
    }

    let report: ParsedHealthReport
    let reader: Reader
    let filename: String
    let pdfData: Data
    let seconds: Double
}

// MARK: - State

enum PDFUploadState: Equatable {
    case idle
    case extracting
    /// Waiting on the private AI; `since` drives the elapsed-time display.
    case parsing(since: Date)
    /// Read; waiting for the user to confirm before anything is saved.
    case review(PDFReadResult)
    /// The AI couldn't read it. Nothing was saved.
    case aiFailed(String)
    case saving
    case done(PDFUploadResult)
    case error(String)

    static func == (lhs: PDFUploadState, rhs: PDFUploadState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.extracting, .extracting), (.saving, .saving): return true
        case (.parsing(let a), .parsing(let b)): return a == b
        case (.aiFailed(let a), .aiFailed(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        case (.review, .review), (.done, .done): return true
        default: return false
        }
    }

    var isWorking: Bool {
        switch self {
        case .extracting, .parsing, .saving: return true
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

    /// Tests replace the AI call.
    var parseWithAI: (String, String) async throws -> AmachAPIClient.AIParseOutcome = { text, filename in
        try await AmachAPIClient.shared.parseReportWithAI(text: text, sourceName: filename)
    }

    // MARK: - Read

    /// Extract and read the PDF with the private AI. Ends in `.review` or
    /// `.aiFailed`; never saves.
    func read(pdfData: Data, filename: String) async {
        state = .extracting
        let text = await Task.detached(priority: .userInitiated) {
            PDFReportParser.extractText(from: pdfData)
        }.value
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .error(PDFUploadError.noTextLayer.localizedDescription)
            return
        }

        let started = Date()
        state = .parsing(since: started)
        do {
            let outcome = try await parseWithAI(text, filename)
            let seconds = Date().timeIntervalSince(started)
            guard let report = outcome.report else {
                state = .aiFailed(Self.aiProblem(outcome.diagnostics?.aiError))
                return
            }
            let reader: PDFReadResult.Reader = outcome.readByAI
                ? .privateAI(model: outcome.diagnostics?.aiServedBy)
                : .serverParser(aiProblem: outcome.diagnostics?.aiError)
            state = .review(PDFReadResult(report: report, reader: reader, filename: filename,
                                          pdfData: pdfData, seconds: seconds))
        } catch {
            state = .aiFailed(Self.describe(error))
        }
    }

    /// After an AI failure, read it with the phone's offline parser instead.
    /// Still ends in `.review`; the user decides whether to save.
    func readOffline(pdfData: Data, filename: String) async {
        state = .extracting
        let started = Date()
        let report = await Task.detached(priority: .userInitiated) {
            PDFReportParser.parseText(PDFReportParser.extractText(from: pdfData), filename: filename)
        }.value
        guard let report else {
            state = .error(PDFUploadError.unrecognizedContent.localizedDescription)
            return
        }
        state = .review(PDFReadResult(report: report, reader: .phoneParser, filename: filename,
                                      pdfData: pdfData, seconds: Date().timeIntervalSince(started)))
    }

    // MARK: - Save

    /// Save a reviewed report in the vault, with its original PDF.
    func save(_ result: PDFReadResult) {
        guard let vault = LocalVault.shared.database else {
            state = .error(PDFUploadError.noVault.localizedDescription)
            return
        }
        state = .saving
        do {
            let reportId = Self.reportId(for: result.report)
            let item = Self.vaultItem(for: result.report, id: reportId,
                                      pdfSHA256: LabVaultMapping.sha256Hex(result.pdfData))
            let savedId: String
            let duplicate: Bool
            switch try vault.saveLabReport(item) {
            case .duplicate(let existingId): savedId = existingId; duplicate = true
            case .inserted: savedId = reportId; duplicate = false
            }
            try vault.saveLabPdf(result.pdfData, reportId: savedId, filename: result.filename)
            // Luma's next message should see this report.
            LabContextService.shared.invalidate()
            state = .done(PDFUploadResult(storjUri: "", contentHash: "", reportId: savedId,
                                          report: result.report, wasDuplicate: duplicate))
        } catch {
            state = .error("Couldn't save the report: \(error.localizedDescription)")
        }
    }

    func reset() { state = .idle }

    // MARK: - Messages

    static func describe(_ error: Error) -> String {
        if case APIError.enclaveBusy = error {
            return "The private AI is busy right now. Nothing was saved. Try again in a minute."
        }
        if case APIError.httpError(let code) = error, code == 504 || code == 502 {
            return "The private AI took too long to read this report. Nothing was saved."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "The private AI took too long to read this report. Nothing was saved."
            case .notConnectedToInternet, .networkConnectionLost:
                return "No connection to the private AI. Nothing was saved."
            default: break
            }
        }
        return "The private AI couldn't read this report (\(error.localizedDescription)). Nothing was saved."
    }

    static func aiProblem(_ reason: String?) -> String {
        let detail = reason.map { " (\($0))" } ?? ""
        return "The private AI couldn't find a report in this PDF\(detail). Nothing was saved."
    }

    static func vaultItem(for report: ParsedHealthReport, id: String, pdfSHA256: String?) -> LabReportWithMarkers {
        switch report {
        case .bloodwork(let bw):
            return LabVaultMapping.bloodwork(bw, id: id, origin: "device", pdfSHA256: pdfSHA256)
        case .dexa(let dexa):
            return LabVaultMapping.dexa(dexa, id: id, origin: "device", pdfSHA256: pdfSHA256)
        case .medicalRecord(let mr):
            return LabVaultMapping.medical(mr, id: id, origin: "device", pdfSHA256: pdfSHA256)
        case .gutHealth(let gut):
            return LabVaultMapping.gutHealth(gut, id: id, origin: "device", pdfSHA256: pdfSHA256)
        }
    }

    // MARK: - Helpers

    static func reportId(for report: ParsedHealthReport) -> String {
        switch report {
        case .bloodwork(let bw): return "bloodwork-\(bw.reportDate ?? timestampString())-\(shortRandom())"
        case .dexa(let dexa): return "dexa-\(dexa.scanDate ?? timestampString())-\(shortRandom())"
        case .medicalRecord(let mr): return "medical-record-\(mr.reportDate ?? timestampString())-\(shortRandom())"
        case .gutHealth(let gut): return "gut-health-\(gut.collectionDate ?? timestampString())-\(shortRandom())"
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
    case noTextLayer
    case noVault
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unrecognizedContent:
            return "The PDF doesn't appear to contain recognizable bloodwork or DEXA data. Try a different file."
        case .noTextLayer:
            return "This PDF has no text to read (it may be a scan). Scanned PDFs aren't supported yet."
        case .noVault:
            return "Connect your wallet to save reports on this phone."
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

