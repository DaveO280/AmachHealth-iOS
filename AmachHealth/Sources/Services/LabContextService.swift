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

    /// Highest `uploadedAt` watermark we used when constructing the cached `context`.
    /// If Storj reports no newer lab uploads than this watermark, we skip full
    /// retrieval/decoding and reuse the existing in-memory context.
    private var lastLabUploadedAt: TimeInterval?
    private let api = AmachAPIClient.shared

    private init() {}

    // MARK: - Public API

    /// Load lab results for Luma context.
    /// Safe to call multiple times; if Storj listing shows no newer labs than
    /// our last watermark, we reuse the existing in-memory `context`.
    /// Pass `force: true` to bypass the watermark check and fully refresh.
    func load(wallet: WalletService, force: Bool = false) async {
        guard !isLoading else { return }
        guard wallet.isConnected else {
            #if DEBUG
            print("🧪 LabContextService: wallet not connected — skipping lab fetch")
            #endif
            return
        }

        isLoading = true
        defer {
            isLoading = false
        }

        do {
            let key = try await wallet.ensureEncryptionKey()
            #if DEBUG
            print("🧪 LabContextService: fetching lab records for \(key.walletAddress.prefix(8))…")
            #endif

            let items = try await api.listLabRecords(
                walletAddress: key.walletAddress,
                encryptionKey: key
            )
            #if DEBUG
            print("🧪 LabContextService: found \(items.count) lab items: \(items.map { "\($0.dataType)@\($0.uploadDate)" })")
            #endif

            // Prioritise FHIR format; fall back to legacy key-value records
            let latestBloodwork = mostRecent(from: items, preferredType: "bloodwork-report-fhir", fallbackType: "bloodwork")
            let latestDexa      = mostRecent(from: items, preferredType: "dexa-report-fhir",      fallbackType: "dexa")
            #if DEBUG
            print("🧪 LabContextService: bloodwork candidate = \(latestBloodwork?.uri ?? "none"), dexa = \(latestDexa?.uri ?? "none")")
            #endif

            // If we already have cached context and Storj reports no newer lab
            // uploads than our last watermark, reuse the cache.
            let candidateUploadedAt = [latestBloodwork?.uploadedAt, latestDexa?.uploadedAt]
                .compactMap { $0 }
                .max()
            if !force,
               context != nil,
               let watermark = lastLabUploadedAt {
                if candidateUploadedAt == nil {
                    return
                }
                if candidateUploadedAt! <= watermark {
                    return
                }
            }

            async let bloodworkCtx = fetchBloodwork(item: latestBloodwork, key: key)
            async let dexaCtx      = fetchDexa(item: latestDexa, key: key)

            let bw = await bloodworkCtx
            let dx = await dexaCtx
            #if DEBUG
            print("🧪 LabContextService: bloodwork decoded = \(bw != nil), dexa decoded = \(dx != nil)")
            #endif

            // Only set context if we actually got something
            if bw != nil || dx != nil {
                context = LabResultsContext(bloodwork: bw, dexa: dx)
                lastLabUploadedAt = candidateUploadedAt
                #if DEBUG
                print("🧪 LabContextService: context set ✅")
                #endif
            } else {
                #if DEBUG
                print("🧪 LabContextService: no data decoded — context remains nil")
                #endif
            }
        } catch {
            #if DEBUG
            print("🧪 LabContextService: load failed — \(error)")
            #endif
            // Non-fatal: Luma works without lab context
        }
    }

    // MARK: - Private Fetch Helpers

    private func fetchBloodwork(item: StorjListItem?, key: WalletEncryptionKey) async -> LabBloodworkContext? {
        guard let item else { return nil }
        do {
            if item.dataType == "bloodwork-report-fhir" {
                // Use report/retrieve — the backend normalizes the stored FHIR
                // blob into the RemoteBloodworkReport shape. storage/retrieve
                // returns the raw blob whose keys don't match our struct.
                let report = try await api.retrieveBloodworkReport(
                    storjUri: item.uri,
                    walletAddress: key.walletAddress,
                    encryptionKey: key
                )
                let ctx = convertBloodworkReport(report)
                #if DEBUG
                print("🧪 LabContextService: FHIR bloodwork → \(ctx?.metrics.count ?? 0) metrics")
                #endif
                return ctx
            } else {
                let record = try await api.retrieveStoredData(
                    storjUri: item.uri,
                    walletAddress: key.walletAddress,
                    encryptionKey: key,
                    as: LabRecord.self
                )
                let ctx = convertLegacyBloodwork(record)
                #if DEBUG
                print("🧪 LabContextService: legacy bloodwork → \(ctx?.metrics.count ?? 0) metrics")
                #endif
                return ctx
            }
        } catch {
            #if DEBUG
            print("🧪 LabContextService: bloodwork fetch/decode failed — \(error)")
            #endif
            return nil
        }
    }

    private func fetchDexa(item: StorjListItem?, key: WalletEncryptionKey) async -> LabDexaContext? {
        guard let item else { return nil }
        do {
            if item.dataType == "dexa-report-fhir" {
                // Use report/retrieve — the backend normalizes the stored FHIR
                // blob into the RemoteDexaReport shape. storage/retrieve
                // returns the raw blob whose keys don't match our struct.
                let report = try await api.retrieveDexaReport(
                    storjUri: item.uri,
                    walletAddress: key.walletAddress,
                    encryptionKey: key
                )
                #if DEBUG
                print("🧪 LabContextService: FHIR dexa → bodyFat=\(report.totalBodyFatPercent as Any)")
                #endif
                return convertDexaReport(report)
            } else {
                let record = try await api.retrieveStoredData(
                    storjUri: item.uri,
                    walletAddress: key.walletAddress,
                    encryptionKey: key,
                    as: LabRecord.self
                )
                #if DEBUG
                print("🧪 LabContextService: legacy dexa → \(record.values.count) values")
                #endif
                return convertLegacyDexa(record)
            }
        } catch {
            #if DEBUG
            print("🧪 LabContextService: dexa fetch/decode failed — \(error)")
            #endif
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
