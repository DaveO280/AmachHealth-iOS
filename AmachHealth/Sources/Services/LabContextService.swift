// LabContextService.swift
// AmachHealth
//
// Fetches and caches the user's most recent bloodwork and DEXA lab results
// for injection into Luma's chat context.
//
// Load lifecycle:
//   • Triggered once when ChatView appears (if wallet is connected)
//   • Results cached in-memory for the session — no redundant API calls
//   • Silently no-ops when wallet is not connected or no records exist
//
// Luma receives the cached context on every message via HealthContextBuilder.

import Foundation

@MainActor
final class LabContextService: ObservableObject {
    static let shared = LabContextService()

    @Published private(set) var context: LabResultsContext? = nil
    @Published private(set) var isLoading = false

    private var hasAttempted = false
    private let api = AmachAPIClient.shared

    private init() {}

    // MARK: - Public API

    /// Load lab results for Luma context. Safe to call multiple times — only
    /// fetches once per app session. Pass force: true to bypass the cache.
    func load(wallet: WalletService, force: Bool = false) async {
        guard !isLoading else { return }
        guard force || !hasAttempted else { return }
        guard wallet.isConnected else { return }

        isLoading = true
        hasAttempted = true
        defer { isLoading = false }

        do {
            let key = try await wallet.ensureEncryptionKey()
            let items = try await api.listLabRecords(
                walletAddress: key.walletAddress,
                encryptionKey: key
            )

            // Prioritise FHIR format; fall back to legacy key-value records
            let latestBloodwork = mostRecent(from: items, preferredType: "bloodwork-report-fhir", fallbackType: "bloodwork")
            let latestDexa      = mostRecent(from: items, preferredType: "dexa-report-fhir",      fallbackType: "dexa")

            async let bloodworkCtx = fetchBloodwork(item: latestBloodwork, key: key)
            async let dexaCtx      = fetchDexa(item: latestDexa, key: key)

            let bw = await bloodworkCtx
            let dx = await dexaCtx

            // Only set context if we actually got something
            if bw != nil || dx != nil {
                context = LabResultsContext(bloodwork: bw, dexa: dx)
            }
        } catch {
            // Non-fatal: Luma works without lab context
        }
    }

    // MARK: - Private Fetch Helpers

    private func fetchBloodwork(item: StorjListItem?, key: WalletEncryptionKey) async -> LabBloodworkContext? {
        guard let item else { return nil }
        do {
            if item.dataType == "bloodwork-report-fhir" {
                let report = try await api.retrieveBloodworkReport(
                    storjUri: item.uri,
                    walletAddress: key.walletAddress,
                    encryptionKey: key
                )
                return convertBloodworkReport(report)
            } else {
                let record = try await api.retrieveStoredData(
                    storjUri: item.uri,
                    walletAddress: key.walletAddress,
                    encryptionKey: key,
                    as: LabRecord.self
                )
                return convertLegacyBloodwork(record)
            }
        } catch {
            return nil
        }
    }

    private func fetchDexa(item: StorjListItem?, key: WalletEncryptionKey) async -> LabDexaContext? {
        guard let item else { return nil }
        do {
            if item.dataType == "dexa-report-fhir" {
                let report = try await api.retrieveDexaReport(
                    storjUri: item.uri,
                    walletAddress: key.walletAddress,
                    encryptionKey: key
                )
                return convertDexaReport(report)
            } else {
                let record = try await api.retrieveStoredData(
                    storjUri: item.uri,
                    walletAddress: key.walletAddress,
                    encryptionKey: key,
                    as: LabRecord.self
                )
                return convertLegacyDexa(record)
            }
        } catch {
            return nil
        }
    }

    // MARK: - Sorting

    /// Returns the most recently uploaded item matching `preferredType`, or
    /// falls back to `fallbackType` if no preferred items exist.
    private func mostRecent(
        from items: [StorjListItem],
        preferredType: String,
        fallbackType: String
    ) -> StorjListItem? {
        let preferred = items
            .filter { $0.dataType == preferredType }
            .sorted { $0.uploadedAt > $1.uploadedAt }

        if let first = preferred.first { return first }

        return items
            .filter { $0.dataType == fallbackType }
            .sorted { $0.uploadedAt > $1.uploadedAt }
            .first
    }

    // MARK: - Conversion: FHIR → Luma context

    private func convertBloodworkReport(_ report: RemoteBloodworkReport) -> LabBloodworkContext? {
        let metrics = report.metrics.compactMap { m -> LabMetricEntry? in
            guard m.value != nil || !(m.valueText?.isEmpty ?? true) else { return nil }
            let numericValue: Double?
            if let v = m.value {
                numericValue = v
            } else if let t = m.valueText, let d = Double(t) {
                numericValue = d
            } else {
                numericValue = nil
            }
            return LabMetricEntry(
                name: m.name,
                value: numericValue,
                unit: m.unit,
                referenceRange: m.referenceRange,
                flag: m.flag,
                panel: m.panel
            )
        }
        guard !metrics.isEmpty else { return nil }
        return LabBloodworkContext(
            reportDate: report.reportDate,
            laboratory: report.laboratory,
            metrics: metrics,
            notes: report.notes
        )
    }

    private func convertDexaReport(_ report: RemoteDexaReport) -> LabDexaContext? {
        return LabDexaContext(
            scanDate: report.scanDate,
            bodyFatPercent: report.totalBodyFatPercent,
            leanMassKg: report.totalLeanMassKg,
            visceralFatRating: report.visceralFatRating,
            androidGynoidRatio: report.androidGynoidRatio,
            boneDensityTScore: report.boneDensityTotal?.tScore,
            boneDensityZScore: report.boneDensityTotal?.zScore,
            notes: report.notes
        )
    }

    // MARK: - Conversion: Legacy LabRecord → Luma context

    /// Standard reference ranges used when a legacy record doesn't include them.
    private static let bloodworkRanges: [String: (range: String, unit: String)] = [
        "glucose":           ("70–99",    "mg/dL"),
        "hba1c":             ("<5.7",      "%"),
        "totalCholesterol":  ("<200",      "mg/dL"),
        "ldl":               ("<100",      "mg/dL"),
        "hdl":               (">40",       "mg/dL"),
        "triglycerides":     ("<150",      "mg/dL"),
        "tsh":               ("0.5–4.5",   "mIU/L"),
        "vitaminD":          ("30–100",    "ng/mL"),
        "ferritin":          ("12–300",    "ng/mL")
    ]

    private func convertLegacyBloodwork(_ record: LabRecord) -> LabBloodworkContext? {
        guard record.type == "bloodwork" || record.type.contains("bloodwork") else { return nil }
        let formatter = ISO8601DateFormatter()
        let metrics = record.values.map { key, value -> LabMetricEntry in
            let info = Self.bloodworkRanges[key]
            return LabMetricEntry(
                name: key,
                value: value,
                unit: record.units[key] ?? info?.unit,
                referenceRange: info?.range,
                flag: nil,
                panel: nil
            )
        }
        return LabBloodworkContext(
            reportDate: formatter.string(from: record.date),
            laboratory: nil,
            metrics: metrics,
            notes: record.notes.map { [$0] }
        )
    }

    private func convertLegacyDexa(_ record: LabRecord) -> LabDexaContext? {
        guard record.type == "dexa" || record.type.contains("dexa") else { return nil }
        let formatter = ISO8601DateFormatter()
        return LabDexaContext(
            scanDate: formatter.string(from: record.date),
            bodyFatPercent: record.values["bodyFatPct"],
            leanMassKg: record.values["leanMassKg"],
            visceralFatRating: record.values["visceralFatLbs"],
            androidGynoidRatio: record.values["androidGynoidRatio"],
            boneDensityTScore: record.values["boneDensityTScore"],
            boneDensityZScore: nil,
            notes: record.notes.map { [$0] }
        )
    }
}
