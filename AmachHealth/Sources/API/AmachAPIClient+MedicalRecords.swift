// AmachAPIClient+MedicalRecords.swift
// AmachHealth
//
// Storj operations for the Medical Records Upload V1 feature.
//
// Storage layout on Storj:
//   dataType "medical-record-blob"     — encrypted raw file bytes (PDF/image)
//   dataType "medical-record-metadata" — encrypted MedicalRecordMetadata JSON sidecar
//
// The metadata sidecar is the queryable index.  The blob is the source-of-truth
// file that is always retained (invariant 2).  Listing retrieves sidecar items
// and deserialises each one into MedicalRecordMetadata.

import Foundation

extension AmachAPIClient {

    // MARK: - Blob upload

    /// Upload the raw file bytes as an encrypted Storj object.
    /// Returns the StorjStoreResult whose storjUri becomes metadata.storjKey.
    func storeMedicalRecordBlob(
        fileData: Data,
        fileName: String,
        mimeType: String,
        category: MedicalRecordCategory,
        recordId: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        struct BlobPayload: Encodable {
            let content: String   // base64-encoded bytes
            let fileName: String
            let mimeType: String
        }

        let payload = BlobPayload(
            content: fileData.base64EncodedString(),
            fileName: fileName,
            mimeType: mimeType
        )

        let request = StorjRequest(
            action: "storage/store",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: AnyCodable(payload),
            dataType: "medical-record-blob",
            options: StorjStoreOptions(metadata: [
                "recordid":  recordId,
                "category":  category.rawValue,
                "mimetype":  mimeType,
                "filename":  fileName,
                "platform":  "ios"
            ])
        )

        let response: StorjResponse<StorjStoreResult> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Medical record blob upload failed")
        }

        return result
    }

    // MARK: - Metadata sidecar

    /// Store the MedicalRecordMetadata as an encrypted JSON sidecar.
    /// Key fields are also written into Storj options.metadata for filtering
    /// without full retrieval (mirrors the timeline-event pattern).
    func storeMedicalRecordMetadata(
        metadata: MedicalRecordMetadata,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        let request = StorjRequest(
            action: "storage/store",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: AnyCodable(metadata),
            dataType: "medical-record-metadata",
            options: StorjStoreOptions(metadata: [
                "recordid":      metadata.id,
                "category":      metadata.category.rawValue,
                "renderinghint": metadata.renderingHint.rawValue,
                "recorddate":    metadata.recordDate,
                "uploadedat":    metadata.uploadedAt,
                "parserstatus":  metadata.parserStatus.rawValue,
                "filename":      metadata.fileName,
                "platform":      "ios",
                "schemaversion": String(metadata.schemaVersion)
            ])
        )

        let response: StorjResponse<StorjStoreResult> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Medical record metadata upload failed")
        }

        return result
    }

    // MARK: - List

    /// List all medical record metadata sidecars for the wallet.
    /// Returns decoded MedicalRecordMetadata items sorted by recordDate desc.
    func listMedicalRecords(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [MedicalRecordMetadata] {
        let items = try await listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: "medical-record-metadata"
        )

        var records: [MedicalRecordMetadata] = []
        records.reserveCapacity(items.count)

        for item in items.sorted(by: { $0.uploadedAt > $1.uploadedAt }) {
            do {
                let record = try await retrieveStoredData(
                    storjUri: item.uri,
                    walletAddress: walletAddress,
                    encryptionKey: encryptionKey,
                    as: MedicalRecordMetadata.self
                )
                records.append(record)
            } catch {
                // Skip decode failures rather than failing the whole list
                continue
            }
        }

        // Sort by recordDate descending (the date the record is *about*)
        return records.sorted { a, b in
            a.recordDate > b.recordDate
        }
    }

    // MARK: - Update metadata sidecar

    /// Overwrite the metadata sidecar for an existing record (e.g. after parser
    /// succeeds or fails, to update parserStatus / parsedDataRef).
    /// The old sidecar is not deleted — Storj key is stable by content hash.
    /// A new sidecar is written; the list will contain both until the old one
    /// is pruned. In V1 the list deduplicates by recordId.
    func updateMedicalRecordMetadata(
        metadata: MedicalRecordMetadata,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        try await storeMedicalRecordMetadata(
            metadata: metadata,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
    }
}
