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

    /// Values kept per repeating marker, including the latest one.
    static let trendPointsPerMarker = 5
    /// Repeating markers kept; those in the latest report come first.
    static let maxTrendMarkers = 40
    /// Medical documents kept, newest first.
    static let maxMedicalDocuments = 5

    /// When a report was added to the app.
    static func uploadedAt(_ report: LabReportWithMarkers) -> Date? {
        report.report.createdAt > 0 ? Date(timeIntervalSince1970: Double(report.report.createdAt) / 1000) : nil
    }

    /// Newest first by the report's own date, else by when it was added.
    /// The vault orders by the date text, which misorders dates like "May 14, 2026".
    static func newestFirst(_ reports: [LabReportWithMarkers]) -> [LabReportWithMarkers] {
        reports.sorted {
            LumaDate.sortDate($0.report.reportDate, uploadedAt: uploadedAt($0))
                > LumaDate.sortDate($1.report.reportDate, uploadedAt: uploadedAt($1))
        }
    }

    /// Latest bloodwork, DEXA and gut report in the vault, earlier reports of
    /// each, earlier values of repeating bloodwork markers, recent medical
    /// documents and an index of everything, in the shape Luma reads.
    static func context(from vault: VaultDatabase) -> LabResultsContext? {
        let bloodworkReports = newestFirst((try? vault.labReports(kind: .bloodwork)) ?? [])
        let dexaReports = newestFirst((try? vault.labReports(kind: .dexa)) ?? [])
        let bloodwork = bloodworkReports.compactMap(bloodworkContext)
        let dexa = dexaReports.compactMap(dexaContext)
        let trends = bloodworkTrends(bloodworkReports)
        let medicalReports = newestFirst((try? vault.labReports(kind: .medical)) ?? [])
        let isGut = { (r: LabReportWithMarkers) in r.report.subtype == "gut-health" }
        let medical = medicalDocuments(medicalReports.filter { !isGut($0) })
        let gut = medicalReports.filter(isGut).map(gutHealth)
        let index = labIndex(bloodworkReports + dexaReports + medicalReports)
        guard !bloodwork.isEmpty || !dexa.isEmpty || !medical.isEmpty || !gut.isEmpty else { return nil }
        return LabResultsContext(bloodwork: bloodwork.first, dexa: dexa.first, bloodworkTrends: trends,
                                 medicalDocuments: medical, gutHealth: gut.first, index: index,
                                 olderBloodwork: Array(bloodwork.dropFirst()), olderDexa: Array(dexa.dropFirst()),
                                 olderGutHealth: Array(gut.dropFirst()))
    }

    private static func bloodworkContext(_ report: LabReportWithMarkers) -> LabBloodworkContext? {
        var bw = shared.convertBloodworkReport(report.asBloodwork)
        bw?.uploadedAt = uploadedAt(report)
        return bw
    }

    private static func dexaContext(_ report: LabReportWithMarkers) -> LabDexaContext? {
        var dx = shared.convertDexaReport(report.asDexa)
        dx?.regions = dexaRegions(report)
        dx?.uploadedAt = uploadedAt(report)
        return dx
    }

    /// Every report, newest first, skipping medical documents with no medical content.
    static func labIndex(_ reports: [LabReportWithMarkers]) -> [LabIndexEntry] {
        newestFirst(reports).compactMap { r in
            let kind: String
            switch r.report.kind {
            case LabReportRow.Kind.bloodwork.rawValue: kind = "Bloodwork"
            case LabReportRow.Kind.dexa.rawValue: kind = "DEXA scan"
            default:
                if r.report.subtype == "gut-health" { kind = "Gut microbiome"; break }
                let record = r.asMedicalRecord
                guard record.summary != MedicalRecordData.noMedicalContentNote else { return nil }
                kind = record.title ?? r.report.title ?? "Medical document"
            }
            return LabIndexEntry(kind: kind, date: r.report.reportDate, uploadedAt: uploadedAt(r),
                                 source: r.report.laboratory ?? r.report.source, valueCount: r.markers.count)
        }
    }

    /// A gut-health report's markers, split into values and species.
    static func gutHealth(_ report: LabReportWithMarkers) -> LabGutHealthContext {
        let all = report.markers.map { m in
            LabGutHealthContext.Value(section: m.panel ?? "other", name: m.name, value: m.value,
                                      text: m.valueText, unit: m.unit, status: m.flag)
        }
        return LabGutHealthContext(
            date: report.report.reportDate, source: report.report.source ?? report.report.laboratory,
            values: all.filter { $0.section != "species" },
            species: all.filter { $0.section == "species" }.sorted { ($0.value ?? 0) > ($1.value ?? 0) },
            uploadedAt: uploadedAt(report)
        )
    }

    /// Markers with numeric values in two or more reports (matched by
    /// canonical name), with their last few values. `reports` is newest first.
    static func bloodworkTrends(_ reports: [LabReportWithMarkers]) -> [LabMarkerTrend] {
        guard reports.count > 1 else { return [] }
        var order: [String] = []
        var names: [String: String] = [:]
        var points: [String: [LabMarkerTrend.Point]] = [:]
        for report in reports {
            var seen = Set<String>()
            for m in report.markers {
                guard let value = m.value ?? m.valueText.flatMap(Double.init),
                      seen.insert(m.canonicalName).inserted else { continue }
                if names[m.canonicalName] == nil {
                    order.append(m.canonicalName)
                    names[m.canonicalName] = m.name
                }
                guard points[m.canonicalName, default: []].count < trendPointsPerMarker else { continue }
                points[m.canonicalName, default: []].append(
                    .init(date: report.report.reportDate, value: value, unit: m.unit))
            }
        }
        return order
            .compactMap { key -> LabMarkerTrend? in
                guard let list = points[key], list.count > 1 else { return nil }
                return LabMarkerTrend(name: names[key] ?? key, points: list)
            }
            .prefix(maxTrendMarkers)
            .map { $0 }
    }

    static func dexaRegions(_ report: LabReportWithMarkers) -> [LabDexaRegionContext] {
        let labels: [String: String] = [
            "body_fat_percent": "body fat", "lean_mass_kg": "lean", "fat_mass_kg": "fat",
            "bone_density_g_cm2": "BMD", "bone_t_score": "T-score", "bone_z_score": "Z-score"
        ]
        return report.dexaRegions.compactMap { group in
            let values = group.markers.compactMap { m -> LabDexaRegionContext.Value? in
                guard let v = m.value else { return nil }
                return .init(label: labels[m.canonicalName] ?? m.name, value: v, unit: m.unit)
            }
            guard !values.isEmpty else { return nil }
            return LabDexaRegionContext(region: group.region.replacingOccurrences(of: "_", with: " "), values: values)
        }
    }

    /// Recent medical documents, skipping ones the parser found no medical content in.
    static func medicalDocuments(_ reports: [LabReportWithMarkers]) -> [LabMedicalDocumentContext] {
        reports.lazy
            .map { ($0.asMedicalRecord, uploadedAt($0)) }
            .filter { $0.0.summary != MedicalRecordData.noMedicalContentNote }
            .map { r, uploaded in
                LabMedicalDocumentContext(
                    title: r.title, date: r.reportDate, documentType: r.documentType, summary: r.summary,
                    findings: r.keyFindings ?? [], diagnoses: r.diagnoses ?? [], medications: r.medications ?? [],
                    uploadedAt: uploaded
                )
            }
            .filter { $0.summary != nil || !$0.findings.isEmpty || !$0.diagnoses.isEmpty || !$0.medications.isEmpty }
            .prefix(maxMedicalDocuments)
            .map { $0 }
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
