// VaultDatabase+Labs.swift
// AmachHealth
//
// lab_reports / lab_markers: storage, plus conversion from the report
// models the app already uses (BloodworkReportData, DexaReportData,
// MedicalRecordData, legacy LabRecord) and back to the shapes the lab
// detail view and Luma context read.

import Foundation
import CryptoKit
import GRDB

extension VaultDatabase {

    enum LabSaveOutcome: Equatable {
        case inserted(String)
        /// Same kind + fingerprint already stored; returns the existing id.
        case duplicate(String)
    }

    @discardableResult
    func saveLabReport(_ item: LabReportWithMarkers) throws -> LabSaveOutcome {
        try dbQueue.write { db in
            if let fp = item.report.fingerprint,
               let existing = try String.fetchOne(
                   db,
                   sql: "SELECT id FROM lab_reports WHERE kind = ? AND fingerprint = ?",
                   arguments: [item.report.kind, fp]
               ), existing != item.report.id {
                return .duplicate(existing)
            }
            try item.report.save(db)
            try LabMarkerRow.filter(Column("report_id") == item.report.id).deleteAll(db)
            for var marker in item.markers {
                marker.id = nil
                marker.reportId = item.report.id
                try marker.insert(db)
            }
            return .inserted(item.report.id)
        }
    }

    func labReports(kind: LabReportRow.Kind? = nil) throws -> [LabReportWithMarkers] {
        try dbQueue.read { db in
            var request = LabReportRow.all()
            if let kind { request = request.filter(Column("kind") == kind.rawValue) }
            let reports = try request
                .order(sql: "COALESCE(report_date, '') DESC, created_at DESC")
                .fetchAll(db)
            return try reports.map { report in
                let markers = try LabMarkerRow
                    .filter(Column("report_id") == report.id)
                    .order(Column("position"))
                    .fetchAll(db)
                return LabReportWithMarkers(report: report, markers: markers)
            }
        }
    }

    func labReport(id: String) throws -> LabReportWithMarkers? {
        try dbQueue.read { db in
            guard let report = try LabReportRow.fetchOne(db, key: id) else { return nil }
            let markers = try LabMarkerRow
                .filter(Column("report_id") == id)
                .order(Column("position"))
                .fetchAll(db)
            return LabReportWithMarkers(report: report, markers: markers)
        }
    }

    func setLabNarrative(reportId: String, narrative: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE lab_reports SET narrative = ? WHERE id = ?", arguments: [narrative, reportId])
        }
    }

    /// Delete a report: its row, its values (cascade) and the original PDF
    /// kept for it. Backup triggers record the deletions, so an encrypted
    /// backup drops it on its next run. Returns false if it didn't exist.
    @discardableResult
    func deleteLabReport(id: String) throws -> Bool {
        let removedPdfs: [String]? = try dbQueue.write { db in
            let shas = try String.fetchAll(db, sql: "SELECT sha256 FROM lab_pdfs WHERE report_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM lab_reports WHERE id = ?", arguments: [id])
            guard db.changesCount > 0 else { return nil }
            try db.execute(sql: "DELETE FROM lab_pdfs WHERE report_id = ?", arguments: [id])
            return shas
        }
        guard let removedPdfs else { return false }
        for sha in removedPdfs {
            try? FileManager.default.removeItem(at: pdfURL(sha256: sha))
        }
        return true
    }

    /// Whether the original PDF is kept on the phone for this report.
    func hasOriginalPdf(reportId: String) -> Bool {
        (try? dbQueue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM lab_pdfs WHERE report_id = ?)", arguments: [reportId])
        }) ?? false
    }

    func labReportCount() throws -> Int {
        try dbQueue.read { db in try LabReportRow.fetchCount(db) }
    }
}

// MARK: - Model → vault

enum LabVaultMapping {

    static func row(
        id: String,
        kind: LabReportRow.Kind,
        reportDate: String?,
        laboratory: String? = nil,
        pdfSHA256: String? = nil,
        subtype: String? = nil,
        title: String? = nil,
        source: String? = nil,
        notes: [String]? = nil,
        fingerprint: String?,
        origin: String,
        storjKey: String? = nil,
        createdAt: Date = Date()
    ) -> LabReportRow {
        let joinedNotes = notes?.filter { !$0.isEmpty }.joined(separator: "\n")
        return LabReportRow(
            id: id,
            kind: kind.rawValue,
            reportDate: reportDate.map(normalizeDate),
            laboratory: laboratory,
            sourcePdfSha256: pdfSHA256,
            createdAt: createdAt.unixMillis,
            subtype: subtype,
            title: title,
            source: source,
            notes: (joinedNotes?.isEmpty ?? true) ? nil : joinedNotes,
            narrative: nil,
            fingerprint: fingerprint,
            origin: origin,
            storjKey: storjKey,
            attestationTxHash: nil
        )
    }

    static func bloodwork(
        _ report: BloodworkReportData, id: String, origin: String,
        pdfSHA256: String? = nil, storjKey: String? = nil, createdAt: Date = Date()
    ) -> LabReportWithMarkers {
        let markers = report.metrics.enumerated().map { index, m in
            LabMarkerRow(
                id: nil, reportId: id, position: index,
                name: m.name, canonicalName: LabMarkerRow.canonicalize(m.name),
                value: m.value, valueText: m.valueText, unit: m.unit,
                referenceRange: m.referenceRange, flag: m.flag, panel: m.panel
            )
        }
        return LabReportWithMarkers(
            report: row(
                id: id, kind: .bloodwork, reportDate: report.reportDate, laboratory: report.laboratory,
                pdfSHA256: pdfSHA256, title: "Bloodwork", source: report.source, notes: report.notes,
                fingerprint: FhirConverter.fingerprintBloodwork(report), origin: origin,
                storjKey: storjKey, createdAt: createdAt
            ),
            markers: markers
        )
    }

    /// DEXA: every summary and regional value becomes a marker; `panel` is the
    /// region ("total" for whole-body values), so nothing is dropped.
    static func dexa(
        _ report: DexaReportData, id: String, origin: String,
        pdfSHA256: String? = nil, storjKey: String? = nil, createdAt: Date = Date()
    ) -> LabReportWithMarkers {
        var markers: [LabMarkerRow] = []
        func add(_ name: String, _ canonical: String, _ value: Double?, _ unit: String?, panel: String) {
            guard let value else { return }
            markers.append(LabMarkerRow(
                id: nil, reportId: id, position: markers.count,
                name: name, canonicalName: canonical,
                value: value, valueText: nil, unit: unit,
                referenceRange: nil, flag: nil, panel: panel
            ))
        }
        add("Body fat", "body_fat_percent", report.totalBodyFatPercent, "%", panel: "total")
        add("Lean mass", "lean_mass_kg", report.totalLeanMassKg, "kg", panel: "total")
        add("Visceral fat rating", "visceral_fat_rating", report.visceralFatRating, nil, panel: "total")
        add("Visceral fat area", "visceral_fat_area_cm2", report.visceralFatAreaCm2, "cm2", panel: "total")
        add("Visceral fat volume", "visceral_fat_volume_cm3", report.visceralFatVolumeCm3, "cm3", panel: "total")
        add("Android/gynoid ratio", "android_gynoid_ratio", report.androidGynoidRatio, nil, panel: "total")
        add("Bone mineral density", "bone_density_g_cm2", report.boneDensityTotal?.bmd, "g/cm2", panel: "total")
        add("Bone T-score", "bone_t_score", report.boneDensityTotal?.tScore, nil, panel: "total")
        add("Bone Z-score", "bone_z_score", report.boneDensityTotal?.zScore, nil, panel: "total")
        for region in report.regions {
            let panel = LabMarkerRow.canonicalize(region.region)
            add("\(region.region) body fat", "body_fat_percent", region.bodyFatPercent, "%", panel: panel)
            add("\(region.region) lean mass", "lean_mass_kg", region.leanMassKg, "kg", panel: panel)
            add("\(region.region) fat mass", "fat_mass_kg", region.fatMassKg, "kg", panel: panel)
            add("\(region.region) bone density", "bone_density_g_cm2", region.boneDensityGPerCm2, "g/cm2", panel: panel)
            add("\(region.region) T-score", "bone_t_score", region.tScore, nil, panel: panel)
            add("\(region.region) Z-score", "bone_z_score", region.zScore, nil, panel: panel)
        }
        return LabReportWithMarkers(
            report: row(
                id: id, kind: .dexa, reportDate: report.scanDate, pdfSHA256: pdfSHA256,
                title: "DEXA Scan", source: report.source, notes: report.notes,
                fingerprint: FhirConverter.fingerprintDexa(report), origin: origin,
                storjKey: storjKey, createdAt: createdAt
            ),
            markers: markers
        )
    }

    /// Medical records: text findings become markers with `value_text`, grouped by panel.
    static func medical(
        _ report: MedicalRecordData, id: String, origin: String, subtype: String? = nil,
        pdfSHA256: String? = nil, storjKey: String? = nil, createdAt: Date = Date()
    ) -> LabReportWithMarkers {
        var markers: [LabMarkerRow] = []
        func add(_ text: String?, panel: String) {
            guard let text, !text.isEmpty else { return }
            markers.append(LabMarkerRow(
                id: nil, reportId: id, position: markers.count,
                name: panel.capitalized, canonicalName: panel,
                value: nil, valueText: text, unit: nil,
                referenceRange: nil, flag: nil, panel: panel
            ))
        }
        add(report.summary, panel: "summary")
        report.keyFindings?.forEach { add($0, panel: "finding") }
        report.diagnoses?.forEach { add($0, panel: "diagnosis") }
        report.medications?.forEach { add($0, panel: "medication") }
        return LabReportWithMarkers(
            report: row(
                id: id, kind: .medical, reportDate: report.reportDate, pdfSHA256: pdfSHA256,
                subtype: subtype ?? report.documentType, title: report.title ?? "Medical Record",
                source: report.source, fingerprint: FhirConverter.fingerprintMedicalRecord(report),
                origin: origin, storjKey: storjKey, createdAt: createdAt
            ),
            markers: markers
        )
    }

    /// Gut health: every {value, unit, status, ref_*} leaf becomes a marker
    /// (panel = the section it sits in), plus the summary numbers, gut type
    /// and species abundances. Shared by PDF import and the Storj import.
    static func gutHealthMarkers(_ root: [String: Any], reportId: String) -> [LabMarkerRow] {
        var markers: [LabMarkerRow] = []
        func add(_ name: String, value: Double?, text: String? = nil, unit: String? = nil,
                 range: String? = nil, flag: String? = nil, panel: String?) {
            markers.append(LabMarkerRow(
                id: nil, reportId: reportId, position: markers.count, name: name,
                canonicalName: LabMarkerRow.canonicalize(name), value: value, valueText: text,
                unit: unit, referenceRange: range, flag: flag, panel: panel
            ))
        }
        func number(_ any: Any?) -> Double? {
            if let n = any as? NSNumber { return n.doubleValue }
            if let s = any as? String { return Double(s) }
            return nil
        }
        func walk(_ value: Any, path: [String]) {
            guard let dict = value as? [String: Any] else { return }
            if let v = number(dict["value"]) {
                let low = number(dict["ref_low"]), high = number(dict["ref_high"])
                let range = (low != nil || high != nil)
                    ? "\(low.map(LabReportWithMarkers.format) ?? "")–\(high.map(LabReportWithMarkers.format) ?? "")" : nil
                add(path.last ?? "value", value: v, unit: dict["unit"] as? String, range: range,
                    flag: dict["status"] as? String, panel: path.dropLast().last)
                return
            }
            for key in dict.keys.sorted() where key != "summary" && key != "species" {
                walk(dict[key]!, path: path + [key])
            }
        }
        if let summary = root["summary"] as? [String: Any] {
            for key in summary.keys.sorted() {
                if let v = number(summary[key]) { add(key, value: v, panel: "summary") }
                else if let t = summary[key] as? String, !t.isEmpty { add(key, value: nil, text: t, panel: "summary") }
            }
        }
        walk(root, path: [])
        for entry in root["species"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String else { continue }
            add(name, value: number(entry["abundance_pct"]), unit: "%",
                flag: entry["classification"] as? String, panel: "species")
        }
        return markers
    }

    static func gutHealth(
        _ report: GutHealthReport, id: String, origin: String, pdfSHA256: String? = nil,
        storjKey: String? = nil, createdAt: Date = Date()
    ) -> LabReportWithMarkers {
        var row = row(
            id: id, kind: .medical, reportDate: report.collectionDate, pdfSHA256: pdfSHA256,
            subtype: "gut-health", title: "Gut Health", source: report.provider,
            notes: report.recommendations.isEmpty ? nil : report.recommendations,
            fingerprint: sha256Hex(report.rawJSON), origin: origin, storjKey: storjKey, createdAt: createdAt
        )
        row.laboratory = report.provider
        return LabReportWithMarkers(report: row, markers: gutHealthMarkers(report.json, reportId: id))
    }

    /// Legacy manual-entry LabRecord (dataType "bloodwork" / "dexa").
    static func legacy(_ record: LabRecord, origin: String, storjKey: String? = nil) -> LabReportWithMarkers {
        let kind: LabReportRow.Kind = record.type.contains("dexa") ? .dexa : (record.type.contains("bloodwork") ? .bloodwork : .medical)
        let markers = record.values.keys.sorted().enumerated().map { index, key in
            LabMarkerRow(
                id: nil, reportId: record.id, position: index,
                name: key, canonicalName: LabMarkerRow.canonicalize(key),
                value: record.values[key], valueText: nil, unit: record.units[key],
                referenceRange: nil, flag: nil, panel: kind == .dexa ? "total" : nil
            )
        }
        let fpSource = record.values.keys.sorted().map { "\($0)=\(record.values[$0] ?? 0)" }.joined(separator: ";")
            + "|\(record.date.timeIntervalSince1970)|\(record.type)"
        var report = row(
            id: record.id, kind: kind, reportDate: ISO8601DateFormatter().string(from: record.date),
            subtype: "manual-entry", title: record.title, notes: record.notes.map { [$0] },
            fingerprint: sha256Hex(fpSource), origin: origin, storjKey: storjKey
        )
        report.attestationTxHash = record.attestationTxHash
        return LabReportWithMarkers(report: report, markers: markers)
    }

    /// "2025-11-14T00:00:00.000Z" → "2025-11-14"; leaves free text alone.
    static func normalizeDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 10 {
            let prefix = String(trimmed.prefix(10))
            if VaultDay.date(prefix) != nil { return prefix }
        }
        return trimmed
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }
}

// MARK: - Vault → existing view/context models

extension LabReportWithMarkers {
    var displayTitle: String {
        switch report.kindValue {
        case .bloodwork: return "Bloodwork"
        case .dexa: return "DEXA Scan"
        case .medical: return report.title ?? "Medical Record"
        }
    }

    /// Two short "name: value unit" strings for list cards.
    var summaryLines: [String] {
        markers.filter { $0.value != nil && ($0.panel == nil || $0.panel == "total" || report.kindValue == .bloodwork) }
            .prefix(2)
            .map { m in
                let value = m.value.map { LabReportWithMarkers.format($0) } ?? (m.valueText ?? "")
                return "\(m.name): \(value)\(m.unit.map { " \($0)" } ?? "")"
            }
    }

    static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    var asBloodwork: RemoteBloodworkReport {
        RemoteBloodworkReport(
            type: "bloodwork", source: report.source, reportDate: report.reportDate,
            laboratory: report.laboratory,
            metrics: markers.map {
                RemoteBloodworkMetric(
                    name: $0.name, value: $0.value, valueText: $0.valueText, unit: $0.unit,
                    referenceRange: $0.referenceRange, panel: $0.panel, flag: $0.flag
                )
            },
            notes: report.notes.map { [$0] }
        )
    }

    var asDexa: RemoteDexaReport {
        func total(_ canonical: String) -> Double? {
            markers.first { $0.panel == "total" && $0.canonicalName == canonical }?.value
        }
        let bmd = total("bone_density_g_cm2"), t = total("bone_t_score"), z = total("bone_z_score")
        return RemoteDexaReport(
            type: "dexa", source: report.source, scanDate: report.reportDate,
            totalBodyFatPercent: total("body_fat_percent"),
            totalLeanMassKg: total("lean_mass_kg"),
            visceralFatRating: total("visceral_fat_rating"),
            visceralFatAreaCm2: total("visceral_fat_area_cm2"),
            visceralFatVolumeCm3: total("visceral_fat_volume_cm3"),
            androidGynoidRatio: total("android_gynoid_ratio"),
            boneDensityTotal: (bmd == nil && t == nil && z == nil) ? nil : RemoteDexaBoneDensity(bmd: bmd, tScore: t, zScore: z),
            notes: report.notes.map { [$0] }
        )
    }

    /// Regional DEXA values grouped by region, for the detail view.
    var dexaRegions: [(region: String, markers: [LabMarkerRow])] {
        let regional = markers.filter { $0.panel != nil && $0.panel != "total" }
        var order: [String] = []
        var groups: [String: [LabMarkerRow]] = [:]
        for m in regional {
            let key = m.panel ?? ""
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(m)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var asMedicalRecord: RemoteMedicalRecord {
        func texts(_ panel: String) -> [String]? {
            let list = markers.filter { $0.panel == panel }.compactMap(\.valueText)
            return list.isEmpty ? nil : list
        }
        return RemoteMedicalRecord(
            type: "medical-record", source: report.source, reportDate: report.reportDate,
            documentType: report.subtype, title: report.title,
            summary: texts("summary")?.first,
            keyFindings: texts("finding"), medications: texts("medication"), diagnoses: texts("diagnosis")
        )
    }
}
