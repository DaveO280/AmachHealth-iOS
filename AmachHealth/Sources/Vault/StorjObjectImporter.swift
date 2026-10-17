// StorjObjectImporter.swift
// AmachHealth
//
// Decrypts one Storj object and writes it into the vault by dataType.
// Kept apart from StorjImportService (network, progress) so it can be tested
// with fixture bytes.
//
// Every known payload shape was written through the backend's
// StorageService.storeHealthData, i.e. "0x" + CryptoJS(JSON.stringify(data)).
// What differs is the JSON inside:
//   • reports (*-report-fhir): a FHIR DiagnosticReport; narratives: a JSON string
//   • iOS merkle-genesis: { content: base64, path, encrypt } (raw file inside)
//   • website merkle-genesis-*: tree / leaves / metadata objects
//   • apple-health-full-export: iOS { metrics: {...}, sleep } per day, or the
//     website's flat { metricKey: {...}, sleep } per day

import Foundation
import CryptoKit
import GRDB

struct StorjObjectImporter {
    let vault: VaultDatabase

    enum Outcome: Equatable {
        /// `leftoverJSON`: decrypted JSON kept in storj_imports when part of the
        /// object had no table to go to.
        case imported(recordType: String, recordId: String?, counts: [String: Int], note: String?, leftoverJSON: String? = nil)
        case duplicate(recordType: String, recordId: String)
        case archived(payloadJSON: String)
        case failed(String)
    }

    func importObject(_ object: AmachAPIClient.RawStorjObject, bytes: Data, passphrase: String) -> Outcome {
        let text: String
        do {
            text = try WalletPayloadDecryptor.decrypt(objectBytes: bytes, passphrase: passphrase)
        } catch {
            return .failed("Decrypt failed: \(error.localizedDescription)")
        }
        var leftover: String?
        let outcome: Outcome
        do {
            outcome = try route(object, json: text, leftover: &leftover)
        } catch {
            return .failed("Couldn't read \(object.dataType): \(error.localizedDescription)")
        }
        if case .imported(let type, let id, let counts, let note, let extra) = outcome {
            return .imported(recordType: type, recordId: id, counts: counts, note: note, leftoverJSON: extra ?? leftover)
        }
        return outcome
    }

    func recordStatus(_ outcome: Outcome, object: AmachAPIClient.RawStorjObject) {
        var status: StorjImportRow.Status
        var recordType: String?, recordId: String?, detail: String?, payload: String?
        switch outcome {
        case .imported(let type, let id, let counts, let note, let extra):
            status = .imported
            recordType = type
            recordId = id
            detail = ([note].compactMap { $0 } + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
                .joined(separator: "; ")
            payload = extra
        case .duplicate(let type, let id):
            status = .duplicate
            recordType = type
            recordId = id
        case .archived(let json):
            status = .archived
            payload = json
        case .failed(let reason):
            status = .failed
            detail = reason
        }
        try? vault.dbQueue.write { db in
            try StorjImportRow(
                objectKey: object.key, dataType: object.dataType, uploadedAt: object.uploadedAt,
                size: object.size, status: status.rawValue, recordType: recordType, recordId: recordId,
                detail: detail, payloadJson: payload, importedAt: Date().unixMillis
            ).save(db)
        }
    }

    // MARK: - Routing

    /// Route by what the JSON looks like, using the dataType as a hint.
    /// Real buckets hold shapes their dataType doesn't promise: test seeds
    /// and older clients stored plain report objects under
    /// "bloodwork-report-fhir", timeline arrays under "timeline-events",
    /// chat under "conversation-history", and so on.
    private func route(_ object: AmachAPIClient.RawStorjObject, json text: String, leftover: inout String?) throws -> Outcome {
        let data = Data(text.utf8)
        let created = Date(unixMillis: object.uploadedAt)
        let dataType = object.dataType
        let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        if dataType.hasSuffix("-narrative"), json is String {
            return try importNarrative(data, object: object, raw: text)
        }
        if let list = json as? [[String: Any]], list.contains(where: { $0["eventType"] != nil }) {
            return try importTimelineList(list)
        }
        guard let dict = json as? [String: Any] else {
            return .archived(payloadJSON: text)
        }

        if dict["resourceType"] as? String == "DiagnosticReport" {
            return try importFhirReport(data, object: object, created: created, leftover: &leftover)
        }
        switch (dict["type"] as? String)?.lowercased() {
        case "bloodwork"? where dict["metrics"] != nil || dict["panels"] != nil:
            return saveLab(LabVaultMapping.bloodwork(Self.bloodwork(from: dict), id: Self.reportId(for: object.key),
                                                     origin: "import", storjKey: object.key, createdAt: created))
        case "dexa"? where dict["values"] == nil:
            return saveLab(LabVaultMapping.dexa(Self.dexa(from: dict), id: Self.reportId(for: object.key),
                                                origin: "import", storjKey: object.key, createdAt: created))
        case "medical-record"?:
            return saveLab(LabVaultMapping.medical(Self.medical(from: dict), id: Self.reportId(for: object.key),
                                                   origin: "import", storjKey: object.key, createdAt: created))
        default:
            break
        }
        if dict["values"] is [String: Any], dict["units"] != nil, dict["type"] != nil {
            let record = try VaultJSON.decoder.decode(LabRecord.self, from: data)
            return saveLab(LabVaultMapping.legacy(record, origin: "import", storjKey: object.key))
        }
        if dict["dailySummaries"] != nil {
            return try importAppleHealth(data, leftover: &leftover)
        }
        if dataType.hasPrefix("apple-health"), let samples = (dict["data"] as? [String: Any]) ?? Optional(dict),
           samples.values.contains(where: { $0 is [[String: Any]] }) {
            return try importAppleHealthSamples(samples, leftover: &leftover, raw: text)
        }
        if dict["eventType"] != nil, dict["id"] != nil {
            return try importTimelineList([dict])
        }
        if let events = (dict["events"] ?? dict["timeline"] ?? dict["items"]) as? [[String: Any]],
           events.contains(where: { $0["eventType"] != nil }) {
            return try importTimelineList(events)
        }
        if dict["messages"] is [[String: Any]] {
            return try importChat(dict, data: data)
        }
        if dict["facts"] != nil || dict["criticalFacts"] != nil {
            return try importMemory(dict, data: data, raw: text, leftover: &leftover)
        }
        if dataType.hasPrefix("merkle-v2") {
            // Spring Push baseline/finish snapshots: separate leaf sets that
            // can cover the same days, with no root of their own. Keep them
            // whole rather than mixing them into the genesis leaves.
            return .archived(payloadJSON: text)
        }
        if dict["leaves"] is [[String: Any]] {
            return try importMerkleLeaves(data)
        }
        if dict["rootPadded"] != nil {
            return try importMerkleRoot(data, raw: text, keepPayload: dict["tree"] != nil, leftover: &leftover)
        }
        if dataType == "gut-health-report" {
            return try importGutHealth(data, object: object, created: created)
        }
        // merkle-genesis (iOS raw file), health-scores,
        // quarterly-aggregate, gut-health-species: no table yet, keep the JSON.
        return .archived(payloadJSON: text)
    }

    // MARK: - Apple Health

    private func importAppleHealth(_ data: Data, leftover: inout String?) throws -> Outcome {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = root["dailySummaries"] as? [String: Any] else {
            throw ImportError.shape("no dailySummaries")
        }
        let isIOS = days.values.contains { ($0 as? [String: Any])?["metrics"] != nil }
        let source: DailyMetricRow.Source = isIOS ? .importIOS : .importWeb
        var rows: [DailyMetricRow] = []
        var unmapped = Set<String>()

        for (dayKey, value) in days {
            guard let dayObj = value as? [String: Any] else { continue }
            let day = LabVaultMapping.normalizeDate(dayKey)
            let metricEntries = isIOS ? (dayObj["metrics"] as? [String: Any] ?? [:]) : dayObj
            for (key, raw) in metricEntries where key != "sleep" {
                guard let summary = raw as? [String: Any] else { continue }
                guard let metric = AmachMetric.resolve(legacyKey: key) else {
                    unmapped.insert(key)
                    continue
                }
                rows.append(DailyMetricRow(
                    day: day, metric: metric.id,
                    total: Self.number(summary["total"]), avg: Self.number(summary["avg"]),
                    min: Self.number(summary["min"]), max: Self.number(summary["max"]),
                    count: Int(Self.number(summary["count"]) ?? 0), source: source
                ))
            }
            if let sleep = dayObj["sleep"] as? [String: Any] {
                var row = DailyMetricRow(day: day, metric: AmachMetric.sleepId,
                                         total: Self.number(sleep["total"]), count: 0, source: source)
                row.sleepInBedMin = Self.number(sleep["inBed"])
                row.sleepAwakeMin = Self.number(sleep["awake"])
                row.sleepCoreMin = Self.number(sleep["core"])
                row.sleepDeepMin = Self.number(sleep["deep"])
                row.sleepRemMin = Self.number(sleep["rem"])
                row.sleepEfficiency = Self.number(sleep["efficiency"])
                rows.append(row)
            }
        }

        var notes: [String] = []
        rows = Self.normalizeImportedUnits(rows, fromIOS: isIOS, notes: &notes)
        let written = try vault.upsertDailyMetrics(rows, policy: .fillImportedOnly)
        if !unmapped.isEmpty {
            notes.append("kept unmapped metrics as JSON: \(unmapped.sorted().joined(separator: ", "))")
            leftover = String(decoding: data, as: UTF8.self)
        }
        let dayCount = Set(rows.map(\.day)).count
        return .imported(recordType: "daily_metrics", recordId: nil,
                         counts: ["daily_metrics": written, "health_days": dayCount],
                         note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    /// Bring older payloads to SCHEMA.md units. iOS stored percentages as
    /// 0–1 and water in litres. The website's XML import kept the export's
    /// units, so distance may be km; a median under 300 is taken as km.
    static func normalizeImportedUnits(_ rows: [DailyMetricRow], fromIOS: Bool, notes: inout [String]) -> [DailyMetricRow] {
        func scaled(_ row: DailyMetricRow, _ factor: Double) -> DailyMetricRow {
            var r = row
            r.total = r.total.map { $0 * factor }
            r.avg = r.avg.map { $0 * factor }
            r.min = r.min.map { $0 * factor }
            r.max = r.max.map { $0 * factor }
            return r
        }
        var kmMetrics = Set<String>()
        if !fromIOS {
            for metric in ["distance_walking_running", "distance_cycling", "distance_swimming"] {
                let totals = rows.filter { $0.metric == metric }.compactMap(\.total).sorted()
                guard !totals.isEmpty else { continue }
                if totals[totals.count / 2] < 300 { kmMetrics.insert(metric) }
            }
            if !kmMetrics.isEmpty { notes.append("distance looked like km, converted to m: \(kmMetrics.sorted().joined(separator: ", "))") }
        }
        return rows.map { row in
            switch row.metric {
            case "blood_oxygen", "body_fat":
                let v = row.avg ?? row.total ?? 0
                return v <= 1.5 ? scaled(row, 100) : row
            case "dietary_water" where fromIOS:
                return scaled(row, 1000)
            case let m where kmMetrics.contains(m):
                return scaled(row, 1000)
            default:
                return row
            }
        }
    }

    /// Per-sample export: { metricKey: [{ startDate, endDate, value, unit, chartData? }] },
    /// the website's (and the test seeds') "apple-health-export". Units come
    /// with each sample, so they are converted exactly rather than guessed.
    private func importAppleHealthSamples(_ samples: [String: Any], leftover: inout String?, raw: String) throws -> Outcome {
        struct Acc { var values: [Double] = []; var sum = 0.0 }
        var byMetricDay: [String: [String: Acc]] = [:]
        var sleep: [String: (total: Double, inBed: Double, awake: Double, core: Double, deep: Double, rem: Double, n: Int)] = [:]
        var unmapped = Set<String>(), badUnits = Set<String>()

        for (key, value) in samples {
            guard let list = value as? [[String: Any]] else { continue }
            let lower = key.lowercased()
            if lower.contains("sleepanalysis") {
                for item in list {
                    guard let start = Self.date(item["startDate"]) else { continue }
                    let end = Self.date(item["endDate"]) ?? start
                    let day = end.vaultDay
                    var acc = sleep[day] ?? (0, 0, 0, 0, 0, 0, 0)
                    acc.n += 1
                    if let minutes = Self.number(item["value"]) {
                        // One summary sample per night: total minutes plus phases.
                        let phases = (item["chartData"] as? [String: Any])?["phases"] as? [String: Any] ?? [:]
                        acc.total += minutes
                        acc.deep += Self.number(phases["deep"]) ?? 0
                        acc.rem += Self.number(phases["rem"]) ?? 0
                        acc.core += Self.number(phases["light"] ?? phases["core"]) ?? 0
                        acc.awake += Self.number(phases["awake"]) ?? 0
                        acc.inBed += Self.number(phases["inBed"]) ?? 0
                    } else {
                        // Stage samples (XML import): duration goes to the stage.
                        let minutes = end.timeIntervalSince(start) / 60
                        let stage = (item["value"] as? String ?? "").lowercased()
                        if stage.contains("inbed") { acc.inBed += minutes }
                        else if stage.contains("awake") { acc.awake += minutes }
                        else if stage.contains("deep") { acc.deep += minutes; acc.total += minutes }
                        else if stage.contains("rem") { acc.rem += minutes; acc.total += minutes }
                        else { acc.core += minutes; acc.total += minutes }
                    }
                    sleep[day] = acc
                }
                continue
            }
            let metricId: String
            if lower.contains("mindfulsession") {
                metricId = AmachMetric.mindfulMinutesId
            } else if let metric = AmachMetric.resolve(legacyKey: key) {
                metricId = metric.id
            } else {
                unmapped.insert(key)
                continue
            }
            let targetUnit = AmachMetric.unit(for: metricId) ?? ""
            for item in list {
                guard let start = Self.date(item["startDate"]), var v = Self.number(item["value"]) else { continue }
                if let unit = item["unit"] as? String {
                    guard let converted = Self.convert(v, from: unit, to: targetUnit) else { badUnits.insert("\(key) \(unit)"); continue }
                    v = converted
                }
                var acc = byMetricDay[metricId, default: [:]][start.vaultDay] ?? Acc()
                acc.values.append(v)
                acc.sum += v
                byMetricDay[metricId, default: [:]][start.vaultDay] = acc
            }
        }

        var rows: [DailyMetricRow] = []
        for (metricId, days) in byMetricDay {
            let aggregation = AmachMetric.byId[metricId]?.aggregation ?? .sum
            for (day, acc) in days {
                switch aggregation {
                case .sum:
                    rows.append(DailyMetricRow(day: day, metric: metricId, total: acc.sum, count: acc.values.count, source: .importWeb))
                case .range, .average:
                    rows.append(DailyMetricRow(day: day, metric: metricId, avg: acc.sum / Double(acc.values.count),
                                               min: acc.values.min(), max: acc.values.max(), count: acc.values.count, source: .importWeb))
                }
            }
        }
        for (day, acc) in sleep {
            var row = DailyMetricRow(day: day, metric: AmachMetric.sleepId, total: acc.total, count: acc.n, source: .importWeb)
            row.sleepInBedMin = acc.inBed
            row.sleepAwakeMin = acc.awake
            row.sleepCoreMin = acc.core
            row.sleepDeepMin = acc.deep
            row.sleepRemMin = acc.rem
            row.sleepEfficiency = acc.inBed > 0 ? acc.total / acc.inBed : nil
            rows.append(row)
        }

        let written = try vault.upsertDailyMetrics(rows, policy: .fillImportedOnly)
        var notes: [String] = []
        if !unmapped.isEmpty { notes.append("unmapped metrics kept as JSON: \(unmapped.sorted().joined(separator: ", "))") }
        if !badUnits.isEmpty { notes.append("samples with unknown units kept as JSON: \(badUnits.sorted().joined(separator: ", "))") }
        if !notes.isEmpty { leftover = raw }
        return .imported(recordType: "daily_metrics", recordId: nil,
                         counts: ["daily_metrics": written, "health_days": Set(rows.map(\.day)).count],
                         note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    /// Convert a sample value from its stated unit to the metric's vault unit.
    /// nil means the unit isn't understood.
    static func convert(_ value: Double, from unit: String, to target: String) -> Double? {
        let u = unit.trimmingCharacters(in: .whitespaces).lowercased()
        let t = target.lowercased()
        // Percentages: HealthKit and older iOS stored 0–1; the vault uses 0–100.
        if t == "%", u == "%" || u.isEmpty { return value <= 1.5 ? value * 100 : value }
        if u.isEmpty || u == t { return value }
        switch (u, t) {
        case ("km", "m"): return value * 1000
        case ("mi", "m"): return value * 1609.344
        case ("ft", "m"): return value * 0.3048
        case ("cm", "m"): return value / 100
        case ("m", "cm"): return value * 100
        case ("in", "cm"): return value * 2.54
        case ("hr", "min"), ("h", "min"): return value * 60
        case ("s", "min"): return value / 60
        case ("lb", "kg"): return value * 0.45359237
        case ("g", "kg"): return value / 1000
        case ("degf", "degc"), ("°f", "degc"): return (value - 32) * 5 / 9
        case ("°c", "degc"): return value
        case ("l", "ml"): return value * 1000
        case ("kj", "kcal"): return value / 4.184
        case ("cal", "kcal"): return value
        case ("count/min", "bpm"), ("bpm", "breaths/min"), ("count/min", "breaths/min"): return value
        default: break
        }
        // Units that mean the same thing written differently.
        let same: [Set<String>] = [
            ["ml/kg·min", "ml/kg/min", "ml/(kg·min)", "ml/kg*min"],
            ["count", "steps"],
            ["kg/m²", "kg/m2", "count"],
            ["mg/dl"], ["mmhg"], ["ms"], ["kcal"], ["min"], ["breaths/min"],
        ]
        if same.contains(where: { $0.contains(u) && $0.contains(t) }) { return value }
        return nil
    }

    // MARK: - Labs

    private func saveLab(_ item: LabReportWithMarkers, note: String? = nil) -> Outcome {
        do {
            switch try vault.saveLabReport(item) {
            case .inserted(let id):
                return .imported(recordType: "lab_reports", recordId: id,
                                 counts: [item.report.kind: 1, "lab_markers": item.markers.count], note: note)
            case .duplicate(let id):
                return .duplicate(recordType: "lab_reports", recordId: id)
            }
        } catch {
            return .failed("Couldn't save report: \(error.localizedDescription)")
        }
    }

    private func importFhirReport(_ data: Data, object: AmachAPIClient.RawStorjObject, created: Date, leftover: inout String?) throws -> Outcome {
        let fhir = try JSONDecoder().decode(FhirDiagnosticReport.self, from: data)
        let id = Self.reportId(for: object.key)
        let source = fhir.conclusion.flatMap(Self.sourceFromConclusion)
        let item: LabReportWithMarkers
        switch object.dataType {
        case "bloodwork-report-fhir":
            guard let bw = FhirConverter.convertFhirToBloodwork(fhir, source: source) else { throw ImportError.shape("not a DiagnosticReport") }
            let withLab = BloodworkReportData(
                type: bw.type, source: bw.source, reportDate: bw.reportDate, laboratory: source,
                panels: bw.panels, metrics: bw.metrics, notes: bw.notes, rawText: bw.rawText, confidence: bw.confidence
            )
            item = LabVaultMapping.bloodwork(withLab, id: id, origin: "import", storjKey: object.key, createdAt: created)
        case "dexa-report-fhir":
            guard let dexa = FhirConverter.convertFhirToDexa(fhir, source: source) else { throw ImportError.shape("not a DiagnosticReport") }
            item = LabVaultMapping.dexa(dexa, id: id, origin: "import", storjKey: object.key, createdAt: created)
        default:
            let record = FhirConverter.convertFhirToMedicalRecord(fhir)
            item = LabVaultMapping.medical(record, id: id, origin: "import", storjKey: object.key, createdAt: created)
        }

        // Check nothing numeric was dropped on the way from FHIR to markers.
        let fhirValues = Self.numericValueCount(fhir)
        let markerValues = item.markers.filter { $0.value != nil }.count
        var note: String?
        if markerValues < fhirValues {
            note = "\(fhirValues - markerValues) FHIR values had no marker; FHIR kept as JSON"
            leftover = String(decoding: data, as: UTF8.self)
        }
        return saveLab(item, note: note)
    }

    /// Gut health: walk the report and turn every {value, unit, status, ref_*}
    /// leaf into a marker; panel = the section it sits in.
    private func importGutHealth(_ data: Data, object: AmachAPIClient.RawStorjObject, created: Date) throws -> Outcome {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.shape("not an object")
        }
        let id = Self.reportId(for: object.key)
        var markers: [LabMarkerRow] = []
        func walk(_ value: Any, path: [String]) {
            guard let dict = value as? [String: Any] else { return }
            if let v = Self.number(dict["value"]) {
                let name = path.last ?? "value"
                let low = Self.number(dict["ref_low"]), high = Self.number(dict["ref_high"])
                let range = (low != nil || high != nil)
                    ? "\(low.map(LabReportWithMarkers.format) ?? "")–\(high.map(LabReportWithMarkers.format) ?? "")" : nil
                markers.append(LabMarkerRow(
                    id: nil, reportId: id, position: markers.count, name: name,
                    canonicalName: LabMarkerRow.canonicalize(name), value: v, valueText: nil,
                    unit: dict["unit"] as? String, referenceRange: range, flag: dict["status"] as? String,
                    panel: path.dropLast().last
                ))
                return
            }
            for key in dict.keys.sorted() { walk(dict[key]!, path: path + [key]) }
        }
        walk(root, path: [])
        var report = LabVaultMapping.row(
            id: id, kind: .medical, reportDate: root["collection_date"] as? String,
            subtype: "gut-health", title: "Gut Health", source: root["provider"] as? String,
            fingerprint: LabVaultMapping.sha256Hex(data), origin: "import", storjKey: object.key, createdAt: created
        )
        report.laboratory = root["provider"] as? String
        // The full report also stays as JSON: it holds text sections the markers don't.
        let outcome = saveLab(LabReportWithMarkers(report: report, markers: markers), note: "full report kept as JSON")
        if case .imported(let type, let id, let counts, let note, _) = outcome {
            return .imported(recordType: type, recordId: id, counts: counts, note: note,
                             leftoverJSON: String(decoding: data, as: UTF8.self))
        }
        return outcome
    }

    private func importNarrative(_ data: Data, object: AmachAPIClient.RawStorjObject, raw: String) throws -> Outcome {
        guard let narrative = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
            throw ImportError.shape("narrative is not a string")
        }
        // The website stores a narrative right after its report; pair them by time.
        let reportType = String(object.dataType.dropLast("-narrative".count))
        let reportDataTypes: [String] = {
            switch reportType {
            case "bloodwork": return ["bloodwork-report-fhir"]
            case "dexa": return ["dexa-report-fhir"]
            case "gut-health": return ["gut-health-report"]
            default: return ["\(reportType)-report-fhir", reportType]
            }
        }()
        let match: String? = try vault.dbQueue.read { db in
            try String.fetchOne(db, sql: """
                SELECT record_id FROM storj_imports
                WHERE data_type IN (\(reportDataTypes.map { _ in "?" }.joined(separator: ",")))
                  AND status IN ('imported', 'duplicate') AND record_id IS NOT NULL
                  AND uploaded_at <= ? AND uploaded_at >= ?
                ORDER BY uploaded_at DESC LIMIT 1
                """, arguments: StatementArguments(reportDataTypes + [object.uploadedAt, object.uploadedAt - 15 * 60 * 1000]))
        }
        guard let reportId = match else { return .archived(payloadJSON: raw) }
        try vault.setLabNarrative(reportId: reportId, narrative: narrative)
        return .imported(recordType: "lab_reports", recordId: reportId, counts: ["narratives": 1], note: nil)
    }

    // MARK: - Timeline

    private func importTimelineList(_ items: [[String: Any]]) throws -> Outcome {
        var inserted = 0, duplicates = 0
        var notes: [String] = []
        var lastId: String?
        for item in items {
            guard JSONSerialization.isValidJSONObject(item) else { continue }
            let data = try JSONSerialization.data(withJSONObject: item)
            let event = try VaultJSON.decoder.decode(TimelineEvent.self, from: data)
            // Unknown web types decode as CUSTOM; keep the original in event_type.
            var row = TimelineEventRow(event: event, origin: "import")
            if let rawType = item["eventType"] as? String {
                row.eventType = rawType
                if TimelineEventType(rawValue: rawType) == nil { notes.append("event type \(rawType) shown as Custom") }
            }
            let isNew: Bool = try vault.dbQueue.write { db in
                if try TimelineEventRow.exists(db, key: row.id) { return false }
                try row.insert(db)
                return true
            }
            if isNew { inserted += 1 } else { duplicates += 1 }
            lastId = event.id
        }
        if inserted == 0, duplicates > 0, items.count == 1, let lastId {
            return .duplicate(recordType: "timeline_events", recordId: lastId)
        }
        return .imported(recordType: "timeline_events", recordId: items.count == 1 ? lastId : nil,
                         counts: ["timeline_events": inserted],
                         note: notes.isEmpty ? nil : Array(Set(notes)).sorted().joined(separator: "; "))
    }

    // MARK: - Chat and memory (iOS and website shapes)

    /// iOS ChatSession, website {session, messages}, or a chat history
    /// {sessionId, messages, summary, rollingMemory}.
    private func importChat(_ dict: [String: Any], data: Data) throws -> Outcome {
        let session: ChatSession
        if let ios = try? VaultJSON.decoder.decode(ChatSession.self, from: data) {
            session = ios
        } else {
            let sessionDict = dict["session"] as? [String: Any] ?? [:]
            let rawId = (sessionDict["id"] ?? dict["sessionId"] ?? dict["id"]) as? String ?? LabVaultMapping.sha256Hex(data)
            let messages = (dict["messages"] as? [[String: Any]] ?? []).enumerated().compactMap { index, m -> ChatMessage? in
                guard let content = m["content"] as? String else { return nil }
                return ChatMessage(id: Self.uuid(from: m["id"] as? String ?? "\(rawId)-\(index)"),
                                   role: MessageRole(rawValue: m["role"] as? String ?? "") ?? .assistant,
                                   content: content, timestamp: Self.date(m["timestamp"]) ?? Date())
            }
            let started = Self.date(sessionDict["startedAt"] ?? dict["createdAt"] ?? dict["startedAt"])
                ?? messages.first?.timestamp ?? Date()
            var s = ChatSession(id: Self.uuid(from: rawId), createdAt: started)
            s.messages = messages
            s.updatedAt = Self.date(dict["updatedAt"]) ?? messages.last?.timestamp ?? started
            s.healthSummary = (sessionDict["summary"] ?? dict["summary"]) as? String
            s.rollingSummary = (dict["rollingSummary"] ?? dict["rollingMemory"]) as? String
            session = s
        }
        let n = try vault.insertMissingChatSessions([session], origin: "import")
        return n == 0 ? .duplicate(recordType: "chat_sessions", recordId: session.id.uuidString)
                      : .imported(recordType: "chat_sessions", recordId: session.id.uuidString,
                                  counts: ["chat_sessions": 1, "chat_messages": session.messages.count], note: nil)
    }

    /// iOS {facts, summaries}, or the website's ConversationMemory /
    /// StorjConversationHistory {criticalFacts, sessions | importantSessions + recentSessions}.
    private func importMemory(_ dict: [String: Any], data: Data, raw: String, leftover: inout String?) throws -> Outcome {
        if dict["facts"] != nil, let ios = try? VaultJSON.decoder.decode(ConversationMemoryStorjPayload.self, from: data) {
            return try mergeMemory(ios, note: nil)
        }
        var skippedCategories = Set<String>()
        let facts: [CriticalFact] = (dict["criticalFacts"] as? [[String: Any]] ?? []).compactMap { f in
            guard let value = f["value"] as? String, let cat = f["category"] as? String else { return nil }
            guard let category = FactCategory(rawValue: cat) else { skippedCategories.insert(cat); return nil }
            return CriticalFact(id: Self.uuid(from: f["id"] as? String ?? value), category: category, value: value,
                                context: f["context"] as? String, dateIdentified: Self.date(f["dateIdentified"]) ?? Date(),
                                isActive: f["isActive"] as? Bool ?? true, lastConfirmed: nil)
        }
        let sessionDicts = ["sessions", "importantSessions", "recentSessions"].flatMap { dict[$0] as? [[String: Any]] ?? [] }
        let summaries: [SessionSummary] = sessionDicts.compactMap { s in
            guard let summary = s["summary"] as? String, !summary.isEmpty, let rawId = s["id"] as? String else { return nil }
            return SessionSummary(
                id: Self.uuid(from: rawId),
                date: Self.date(s["date"] ?? s["startedAt"]) ?? Date(),
                summary: summary, topics: s["topics"] as? [String] ?? [],
                importance: MemoryImportance(rawValue: s["importance"] as? String ?? "") ?? .medium,
                messageCount: Int(Self.number(s["messageCount"]) ?? 0)
            )
        }
        var notes: [String] = []
        if !skippedCategories.isEmpty {
            notes.append("fact categories not in this app: \(skippedCategories.sorted().joined(separator: ", "))")
        }
        if let prefs = dict["preferences"] as? [String: Any], !prefs.isEmpty {
            notes.append("preferences have no table yet")
        }
        if !notes.isEmpty {
            leftover = raw
            notes.append("full object kept as JSON")
        }
        return try mergeMemory(ConversationMemoryStorjPayload(facts: facts, summaries: summaries),
                               note: notes.isEmpty ? nil : notes.joined(separator: "; "))
    }

    private func mergeMemory(_ remote: ConversationMemoryStorjPayload, note: String?) throws -> Outcome {
        let local = try vault.loadMemory()
        let merged = ConversationMemoryStore.merge(local: local, remote: remote)
        try vault.replaceMemory(facts: merged.facts, summaries: merged.summaries)
        return .imported(recordType: "memory", recordId: nil,
                         counts: ["memory_facts": remote.facts.count, "memory_summaries": remote.summaries.count], note: note)
    }

    // MARK: - Merkle

    private func importMerkleLeaves(_ data: Data) throws -> Outcome {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let leaves = root["leaves"] as? [[String: Any]] else { throw ImportError.shape("no leaves") }
        let rows: [MerkleLeafRow] = leaves.compactMap { leaf in
            guard let dayId = Self.number(leaf["dayId"]) else { return nil }
            let hash = (leaf["hashDec"] as? String).map(Self.decimalToHex) ?? (leaf["hash"] as? String ?? "")
            var fields = leaf
            fields.removeValue(forKey: "hashDec")
            let json = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            return MerkleLeafRow(dayId: Int(dayId), leafVersion: Int(Self.number(leaf["version"]) ?? 1), fields: json, hash: hash)
        }
        try vault.dbQueue.write { db in for row in rows { try row.save(db) } }
        return .imported(recordType: "merkle_leaves", recordId: nil, counts: ["merkle_leaves": rows.count], note: nil)
    }

    private func importMerkleRoot(_ data: Data, raw: String, keepPayload: Bool, leftover: inout String?) throws -> Outcome {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rootHex = root["rootPadded"] as? String,
              let start = Self.number(root["startDayId"]), let end = Self.number(root["endDayId"]) else {
            throw ImportError.shape("no rootPadded/startDayId/endDayId")
        }
        try vault.dbQueue.write { db in
            let existing = try MerkleRootRow.fetchOne(db, key: rootHex)
            try MerkleRootRow(
                root: rootHex, startDay: Int(start), endDay: Int(end), txHash: existing?.txHash,
                leafCount: Self.number(root["leafCount"]).map(Int.init), treeDepth: Self.number(root["treeDepth"]).map(Int.init),
                createdAt: existing?.createdAt ?? Date().unixMillis
            ).save(db)
        }
        if keepPayload { leftover = raw }  // the full tree levels
        return .imported(recordType: "merkle_roots", recordId: rootHex, counts: ["merkle_roots": 1], note: nil)
    }

    // MARK: - Helpers

    enum ImportError: LocalizedError {
        case shape(String)
        var errorDescription: String? {
            switch self { case .shape(let what): return "unexpected payload (\(what))" }
        }
    }

    static func number(_ any: Any?) -> Double? {
        switch any {
        case let n as NSNumber where !(n === kCFBooleanTrue || n === kCFBooleanFalse): return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// ISO-8601 string, or Unix seconds / ms.
    static func date(_ any: Any?) -> Date? {
        if let s = any as? String { return VaultJSON.parseISODate(s) }
        if let n = number(any) { return n > 100_000_000_000 ? Date(unixMillis: Int64(n)) : Date(timeIntervalSince1970: n) }
        return nil
    }

    static func bloodwork(from d: [String: Any]) -> BloodworkReportData {
        func metric(_ m: [String: Any]) -> BloodworkMetric? {
            guard let name = m["name"] as? String else { return nil }
            let value = number(m["value"])
            return BloodworkMetric(
                name: name, value: value,
                valueText: m["valueText"] as? String ?? (value == nil ? m["value"] as? String : nil),
                unit: (m["unit"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                referenceRange: m["referenceRange"] as? String, panel: m["panel"] as? String,
                collectedAt: m["collectedAt"] as? String, flag: m["flag"] as? String,
                interpretationNotes: m["interpretationNotes"] as? [String]
            )
        }
        var metrics = (d["metrics"] as? [[String: Any]] ?? []).compactMap(metric)
        if metrics.isEmpty, let panels = d["panels"] as? [String: Any] {
            for key in panels.keys.sorted() {
                for m in panels[key] as? [[String: Any]] ?? [] {
                    var withPanel = m
                    if withPanel["panel"] == nil { withPanel["panel"] = key }
                    if let parsed = metric(withPanel) { metrics.append(parsed) }
                }
            }
        }
        return BloodworkReportData(
            type: "bloodwork", source: d["source"] as? String, reportDate: d["reportDate"] as? String,
            laboratory: d["laboratory"] as? String, panels: [:], metrics: metrics,
            notes: d["notes"] as? [String], rawText: "", confidence: number(d["confidence"]) ?? 0
        )
    }

    static func dexa(from d: [String: Any]) -> DexaReportData {
        let bone = d["boneDensityTotal"] as? [String: Any]
        let regions = (d["regions"] as? [[String: Any]] ?? []).compactMap { r -> DexaRegionMetrics? in
            guard let region = r["region"] as? String else { return nil }
            return DexaRegionMetrics(region: region, bodyFatPercent: number(r["bodyFatPercent"]), leanMassKg: number(r["leanMassKg"]),
                                     fatMassKg: number(r["fatMassKg"]), boneDensityGPerCm2: number(r["boneDensityGPerCm2"]),
                                     tScore: number(r["tScore"]), zScore: number(r["zScore"]))
        }
        return DexaReportData(
            type: "dexa", source: d["source"] as? String, scanDate: d["scanDate"] as? String,
            totalBodyFatPercent: number(d["totalBodyFatPercent"]), totalLeanMassKg: number(d["totalLeanMassKg"]),
            visceralFatRating: number(d["visceralFatRating"]), visceralFatAreaCm2: number(d["visceralFatAreaCm2"]),
            visceralFatVolumeCm3: number(d["visceralFatVolumeCm3"]),
            boneDensityTotal: bone.map { DexaBoneDensityTotal(bmd: number($0["bmd"]), tScore: number($0["tScore"]), zScore: number($0["zScore"])) },
            androidGynoidRatio: number(d["androidGynoidRatio"]), regions: regions,
            notes: d["notes"] as? [String], rawText: "", confidence: number(d["confidence"]) ?? 0
        )
    }

    static func medical(from d: [String: Any]) -> MedicalRecordData {
        MedicalRecordData(
            type: "medical-record", source: d["source"] as? String, reportDate: d["reportDate"] as? String,
            documentType: d["documentType"] as? String, title: d["title"] as? String, summary: d["summary"] as? String,
            keyFindings: d["keyFindings"] as? [String], medications: d["medications"] as? [String],
            diagnoses: d["diagnoses"] as? [String], rawText: "", confidence: number(d["confidence"]) ?? 0
        )
    }

    static func reportId(for objectKey: String) -> String {
        "storj-" + LabVaultMapping.sha256Hex(objectKey).prefix(20)
    }

    /// "Bloodwork report from Quest." → "Quest"
    static func sourceFromConclusion(_ conclusion: String) -> String? {
        guard let range = conclusion.range(of: "from ") else { return nil }
        var tail = String(conclusion[range.upperBound...])
        if let dot = tail.firstIndex(of: ".") { tail = String(tail[..<dot]) }
        let trimmed = tail.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func numericValueCount(_ fhir: FhirDiagnosticReport) -> Int {
        (fhir.contained ?? []).reduce(0) { total, obs in
            total + (obs.valueQuantity == nil ? 0 : 1) + (obs.component ?? []).filter { $0.valueQuantity != nil }.count
        }
    }

    /// Stable UUID for ids that aren't UUIDs (website ids), from SHA-256.
    static func uuid(from string: String) -> UUID {
        if let uuid = UUID(uuidString: string) { return uuid }
        var bytes = Array(SHA256.hash(data: Data(string.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Arbitrary-size decimal string → "0x" hex (Poseidon hashes exceed UInt64).
    static func decimalToHex(_ decimal: String) -> String {
        var digits = decimal.compactMap { $0.wholeNumberValue }
        guard !digits.isEmpty else { return "0x0" }
        var hex: [Character] = []
        let alphabet = Array("0123456789abcdef")
        while !(digits.count == 1 && digits[0] == 0) {
            var remainder = 0
            var next: [Int] = []
            for d in digits {
                let value = remainder * 10 + d
                let q = value / 16
                remainder = value % 16
                if !next.isEmpty || q != 0 { next.append(q) }
            }
            hex.append(alphabet[remainder])
            digits = next.isEmpty ? [0] : next
        }
        return "0x" + (hex.isEmpty ? "0" : String(hex.reversed()))
    }
}
