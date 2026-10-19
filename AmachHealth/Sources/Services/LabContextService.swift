// LabContextService.swift
// AmachHealth
//
// Builds the user's most recent bloodwork and DEXA results for Luma's chat
// context, from the vault (lab_reports / lab_markers).
//
// Load lifecycle:
//   • Triggered when ChatView appears; reads the vault, so it works offline
//   • Results cached in-memory until invalidate() (new upload, vault change)
//   • Without a vault (no wallet) there are no lab results
//
// Luma receives the cached context on every message via HealthContextBuilder.

import Foundation

@MainActor
final class LabContextService: ObservableObject {
    static let shared = LabContextService()

    @Published private(set) var context: LabResultsContext? = nil
    @Published private(set) var isLoading = false

    private init() {}

    /// Clear the in-memory cache so the next `load()` re-reads the vault.
    func invalidate() {
        context = nil
    }

    // MARK: - Public API

    /// Load lab results for Luma context from the vault, cached in memory.
    /// Pass `force: true` to re-read (e.g. after the user uploads new labs).
    func load(wallet: WalletService, force: Bool = false) async {
        guard !isLoading else { return }
        if !force, context != nil { return }
        if let vault = LocalVault.shared.database {
            context = Self.context(from: vault)
        }
    }

    /// The cached context, filled from the vault first if it's empty.
    /// Synchronous so the chat context builder can always include labs.
    func currentContext() -> LabResultsContext? {
        if context == nil, let vault = LocalVault.shared.database {
            context = Self.context(from: vault)
        }
        return context
    }

    // MARK: - Vault

    /// Latest bloodwork and DEXA in the vault, in the shape Luma reads.
    static func context(from vault: VaultDatabase) -> LabResultsContext? {
        let bloodwork = (try? vault.labReports(kind: .bloodwork))?.first
        let dexa = (try? vault.labReports(kind: .dexa))?.first
        let bw = bloodwork.flatMap { shared.convertBloodworkReport($0.asBloodwork) }
        let dx = dexa.map { shared.convertDexaReport($0.asDexa) } ?? nil
        guard bw != nil || dx != nil else { return nil }
        return LabResultsContext(bloodwork: bw, dexa: dx)
    }

    // MARK: - Private Fetch Helpers

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
