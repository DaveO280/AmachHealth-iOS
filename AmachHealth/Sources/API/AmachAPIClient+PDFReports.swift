// AmachAPIClient+PDFReports.swift
// AmachHealth
//
// API client extension: store FHIR-formatted bloodwork and DEXA reports.
// Uses the same storage/store → /api/storj route as all other data types.
// dataType values ("bloodwork-report-fhir", "dexa-report-fhir") match the website.

import Foundation

extension AmachAPIClient {

    /// Upload a FHIR DiagnosticReport to Storj.
    /// Used by PDFUploadService for both bloodwork and DEXA scans.
    func storeFhirReport(
        fhirReport: FhirDiagnosticReport,
        dataType: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        metadata: [String: String]
    ) async throws -> StorjStoreResult {
        let request = StorjRequest(
            action: "storage/store",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: AnyCodable(fhirReport),
            dataType: dataType,
            options: StorjStoreOptions(metadata: metadata)
        )

        let response: StorjResponse<StorjStoreResult> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "FHIR report store failed")
        }

        return result
    }

    /// Retrieve a stored bloodwork FHIR report and convert it back to BloodworkReportData.
    func retrieveBloodworkFhirReport(
        storjUri: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> BloodworkReportData {
        let fhir: FhirDiagnosticReport = try await retrieveStoredData(
            storjUri: storjUri,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
        guard let report = FhirConverter.convertFhirToBloodwork(fhir) else {
            throw APIError.requestFailed("Failed to decode bloodwork FHIR report")
        }
        return report
    }

    /// Retrieve a stored DEXA FHIR report and convert it back to DexaReportData.
    func retrieveDexaFhirReport(
        storjUri: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> DexaReportData {
        let fhir: FhirDiagnosticReport = try await retrieveStoredData(
            storjUri: storjUri,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
        guard let report = FhirConverter.convertFhirToDexa(fhir) else {
            throw APIError.requestFailed("Failed to decode DEXA FHIR report")
        }
        return report
    }
}
