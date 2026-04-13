// MedicalRecordUploadService.swift
// AmachHealth
//
// Orchestrates the Medical Records Upload V1 pipeline.
//
// Lane B (document-only):
//   1. Upload raw file blob (dataType: "medical-record-blob")
//   2. Write metadata sidecar (dataType: "medical-record-metadata")
//   3. Create timeline event
//
// Lane A (structured):
//   1. Upload raw file blob
//   2. Run existing PDFUploadService parser (bloodwork-report-fhir / dexa-report-fhir)
//   3. Write metadata sidecar linking blob storjKey + parsedDataRef
//
// Invariants enforced here:
//   - Original blob is always retained regardless of parser outcome (invariant 2)
//   - Parser failure for Lane A falls back to document-only display while
//     retaining original category for future retry (invariant 6)

import Foundation

// MARK: - MIME helpers

private enum MimeType {
    static func mimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":        return "application/pdf"
        case "jpg", "jpeg":return "image/jpeg"
        case "png":        return "image/png"
        case "heic":       return "image/heic"
        default:           return "application/octet-stream"
        }
    }
}

// MARK: - Date formatter (yyyy-MM-dd)

private extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
}

// MARK: - Service

@MainActor
final class MedicalRecordUploadService: ObservableObject {
    @Published var state: MedicalRecordUploadState = .idle

    static let shared = MedicalRecordUploadService()
    private init() {}

    // MARK: - Public

    /// Upload a medical record file with user-supplied categorisation metadata.
    ///
    /// - Parameters:
    ///   - fileData:      Raw bytes of the file (PDF, JPEG, PNG, HEIC).
    ///   - fileName:      Original filename (used for display and MIME detection).
    ///   - category:      User-selected category — determines which lane is used.
    ///   - recordDate:    The date the record is *about* (required by spec).
    ///   - providerName:  Optional provider / lab name.
    ///   - notes:         Optional free-text notes from the user.
    ///   - walletAddress: Wallet address for Storj auth.
    ///   - encryptionKey: Derived encryption key from WalletService.
    func upload(
        fileData: Data,
        fileName: String,
        category: MedicalRecordCategory,
        recordDate: Date,
        providerName: String?,
        notes: String?,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> MedicalRecordUploadResult {
        let recordId     = UUID().uuidString
        let mimeType     = MimeType.mimeType(for: fileName)
        let recordDateISO = ISO8601DateFormatter.dateOnly.string(from: recordDate)
        let uploadedAtISO = ISO8601DateFormatter().string(from: Date())

        // Step 1: Upload raw blob (retained regardless of parser outcome — invariant 2)
        state = .uploading(progress: 0.1)
        let blobResult = try await AmachAPIClient.shared.storeMedicalRecordBlob(
            fileData: fileData,
            fileName: fileName,
            mimeType: mimeType,
            category: category,
            recordId: recordId,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )

        // Construct initial metadata
        var metadata = MedicalRecordMetadata(
            id: recordId,
            storjKey: blobResult.storjUri,
            fileName: fileName,
            mimeType: mimeType,
            sizeBytes: fileData.count,
            uploadedAt: uploadedAtISO,
            recordDate: recordDateISO,
            category: category,
            renderingHint: category.renderingHint,
            notes: notes.flatMap { $0.isEmpty ? nil : $0 },
            providerName: providerName.flatMap { $0.isEmpty ? nil : $0 },
            parserStatus: category.isLaneA ? .pending : .notApplicable,
            parsedDataRef: nil,
            schemaVersion: 1
        )

        state = .uploading(progress: 0.3)

        // Step 2: Lane A — delegate to existing structured parser
        if category.isLaneA {
            metadata = await runLaneAParser(
                fileData: fileData,
                fileName: fileName,
                mimeType: mimeType,
                metadata: metadata,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
        }

        state = .uploading(progress: 0.7)

        // Step 3: Write metadata sidecar
        let metadataResult = try await AmachAPIClient.shared.storeMedicalRecordMetadata(
            metadata: metadata,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )

        state = .uploading(progress: 0.9)

        // Step 4: Lane B — create timeline event
        if !category.isLaneA {
            await createTimelineEvent(
                metadata: metadata,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
        }

        let result = MedicalRecordUploadResult(
            metadata: metadata,
            metadataStorjUri: metadataResult.storjUri,
            blobStorjUri: blobResult.storjUri
        )
        state = .done(result)
        return result
    }

    func reset() { state = .idle }

    // MARK: - Lane A parser

    /// Runs the existing PDFUploadService on the file and returns updated metadata.
    /// On failure, parserStatus is set to .failed but the original category and
    /// renderingHint are retained (spec invariant 6 — allows future retry).
    /// Non-PDF uploads are marked .skipped (can't parse images in v1).
    private func runLaneAParser(
        fileData: Data,
        fileName: String,
        mimeType: String,
        metadata: MedicalRecordMetadata,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async -> MedicalRecordMetadata {
        guard mimeType == "application/pdf" else {
            return metadata.withParserStatus(.skipped, parsedDataRef: nil)
        }

        do {
            let pdfResult = try await PDFUploadService.shared.upload(
                pdfData: fileData,
                filename: fileName,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
            return metadata.withParserStatus(.succeeded, parsedDataRef: pdfResult.storjUri)
        } catch {
            // Parser failed — fall back to document-only display while retaining
            // original category so the user can retry from the record detail view.
            return metadata.withParserStatus(.failed, parsedDataRef: nil)
        }
    }

    // MARK: - Timeline event (Lane B only)

    private func createTimelineEvent(
        metadata: MedicalRecordMetadata,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async {
        // Parse the yyyy-MM-dd recordDate back to a Date for the event timestamp
        let eventDate = ISO8601DateFormatter.dateOnly.date(from: metadata.recordDate) ?? Date()

        var eventData: [String: String] = [
            "category": metadata.category.displayName,
            "fileName": metadata.fileName
        ]
        if let provider = metadata.providerName { eventData["provider"] = provider }
        if let notes = metadata.notes          { eventData["notes"]    = notes    }

        let event = TimelineEvent(
            id: "medrecord-\(metadata.id)",
            eventType: .generalNote,
            timestamp: eventDate,
            data: eventData,
            metadata: TimelineEventMetadata(
                platform: "ios",
                version: "1",
                source: .userEntered
            )
        )

        _ = try? await StorjTimelineService.shared.saveEvent(
            event,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
    }
}

// MARK: - MedicalRecordMetadata helpers

private extension MedicalRecordMetadata {
    /// Return a copy with updated parserStatus and parsedDataRef.
    func withParserStatus(
        _ status: MedicalRecordParserStatus,
        parsedDataRef ref: String?
    ) -> MedicalRecordMetadata {
        MedicalRecordMetadata(
            id: id,
            storjKey: storjKey,
            fileName: fileName,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            uploadedAt: uploadedAt,
            recordDate: recordDate,
            category: category,
            renderingHint: renderingHint,
            notes: notes,
            providerName: providerName,
            parserStatus: status,
            parsedDataRef: ref,
            schemaVersion: schemaVersion
        )
    }
}
