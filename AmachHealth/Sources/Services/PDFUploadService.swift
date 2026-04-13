// PDFUploadService.swift
// AmachHealth
//
// Orchestrates the PDF → Storj pipeline:
//   1. Extract text with PDFKit
//   2. Normalize to BloodworkReportData or DexaReportData
//   3. Compute fingerprint for duplicate detection
//   4. Check for existing upload (by fingerprint in metadata)
//   5. Convert to FHIR DiagnosticReport
//   6. Store on Storj (dataType: bloodwork-report-fhir or dexa-report-fhir)
//   7. Optionally create ZKsync attestation
//
// Matches the website's StorjReportService.ts logic.

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

    /// Parse a PDF and upload it to Storj as a FHIR report.
    /// Reports already on Storj (matched by fingerprint) are returned directly without re-upload.
    func upload(
        pdfData: Data,
        filename: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> PDFUploadResult {
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

        let (fhirReport, dataType, fingerprint, reportId) = buildFhirPayload(from: report)

        // Step 3: Dedup check
        let existing = try? await checkForDuplicate(
            fingerprint: fingerprint,
            dataType: dataType,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
        if let dup = existing {
            let result = PDFUploadResult(
                storjUri: dup.storjUri,
                contentHash: dup.contentHash,
                reportId: dup.reportId ?? reportId,
                report: report,
                wasDuplicate: true
            )
            state = .done(result)
            return result
        }

        // Step 4: Upload
        state = .uploading(progress: 0.1)
        let metadata = buildMetadata(report: report, fingerprint: fingerprint, reportId: reportId)
        let storeResult = try await AmachAPIClient.shared.storeFhirReport(
            fhirReport: fhirReport,
            dataType: dataType,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            metadata: metadata
        )
        state = .uploading(progress: 0.8)

        // Step 5: Attestation (fire-and-forget)
        _ = try? await AmachAPIClient.shared.createAttestation(
            storjUri: storeResult.storjUri,
            dataType: dataType,
            action: "store",
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            metadata: metadata
        )

        state = .uploading(progress: 1.0)
        let result = PDFUploadResult(
            storjUri: storeResult.storjUri,
            contentHash: storeResult.contentHash,
            reportId: reportId,
            report: report,
            wasDuplicate: false
        )
        state = .done(result)
        return result
    }

    func reset() { state = .idle }

    // MARK: - Helpers

    private func buildFhirPayload(from report: ParsedHealthReport) -> (FhirDiagnosticReport, String, String, String) {
        switch report {
        case .bloodwork(let bw):
            let fhir = FhirConverter.convertBloodworkToFhir(bw)
            let fingerprint = FhirConverter.fingerprintBloodwork(bw)
            let reportId = "bloodwork-\(bw.reportDate ?? timestampString())-\(shortRandom())"
            return (fhir, "bloodwork-report-fhir", fingerprint, reportId)
        case .dexa(let dexa):
            let fhir = FhirConverter.convertDexaToFhir(dexa)
            let fingerprint = FhirConverter.fingerprintDexa(dexa)
            let reportId = "dexa-\(dexa.scanDate ?? timestampString())-\(shortRandom())"
            return (fhir, "dexa-report-fhir", fingerprint, reportId)
        case .medicalRecord(let mr):
            let fhir = FhirConverter.convertMedicalRecordToFhir(mr)
            let fingerprint = FhirConverter.fingerprintMedicalRecord(mr)
            let reportId = "medical-record-\(mr.reportDate ?? timestampString())-\(shortRandom())"
            return (fhir, "medical-record-fhir", fingerprint, reportId)
        }
    }

    private func checkForDuplicate(
        fingerprint: String,
        dataType: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> (storjUri: String, contentHash: String, reportId: String?)? {
        let items = try await AmachAPIClient.shared.listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: dataType
        )
        for item in items {
            let md = item.metadata ?? [:]
            let fp = md["reportfingerprint"] ?? md["reportFingerprint"] ?? ""
            guard !fp.isEmpty, fp == fingerprint else { continue }
            return (item.uri, item.contentHash, md["reportid"] ?? md["reportId"])
        }
        return nil
    }

    private func buildMetadata(
        report: ParsedHealthReport,
        fingerprint: String,
        reportId: String
    ) -> [String: String] {
        var metadata: [String: String] = [
            "reportid": reportId,
            "format": "fhir-r4",
            "reportfingerprint": fingerprint,
            "platform": "ios",
        ]
        switch report {
        case .bloodwork(let bw):
            metadata["reporttype"] = "bloodwork"
            if let date = bw.reportDate { metadata["reportdate"] = date }
            if let src = bw.source { metadata["source"] = src }
            metadata["confidence"] = String(bw.confidence)
            metadata["metriccount"] = String(bw.metrics.count)
        case .dexa(let dexa):
            metadata["reporttype"] = "dexa"
            if let date = dexa.scanDate { metadata["scandate"] = date }
            if let src = dexa.source { metadata["source"] = src }
            metadata["confidence"] = String(dexa.confidence)
            metadata["regioncount"] = String(dexa.regions.count)
        case .medicalRecord(let mr):
            metadata["reporttype"] = "medical-record"
            if let date = mr.reportDate { metadata["reportdate"] = date }
            if let src = mr.source { metadata["source"] = src }
            if let docType = mr.documentType { metadata["documenttype"] = docType }
            if let title = mr.title { metadata["title"] = title }
            metadata["confidence"] = String(mr.confidence)
        }
        return metadata
    }

    private func timestampString() -> String {
        String(Int(Date().timeIntervalSince1970))
    }

    private func shortRandom() -> String {
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

