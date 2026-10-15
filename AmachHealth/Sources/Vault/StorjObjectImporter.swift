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

    private func route(_ object: AmachAPIClient.RawStorjObject, json text: String, leftover: inout String?) throws -> Outcome {
        let data = Data(text.utf8)
        let created = Date(unixMillis: object.uploadedAt)
        switch object.dataType {
        case "apple-health-full-export":
            return try importAppleHealth(data, leftover: &leftover)
        case "bloodwork-report-fhir", "dexa-report-fhir", "medical-record-fhir":
            return try importFhirReport(data, object: object, created: created, leftover: &leftover)
        case "bloodwork", "dexa":
            let record = try VaultJSON.decoder.decode(LabRecord.self, from: data)
            return saveLab(LabVaultMapping.legacy(record, origin: "import", storjKey: object.key))
        case "gut-health-report":
            return try importGutHealth(data, object: object, created: created)
        case let type where type.hasSuffix("-narrative"):
            return try importNarrative(data, object: object, raw: text)
        case "timeline-event":
            return try importTimelineEvent(data)
        case "chat-session":
            let session = try VaultJSON.decoder.decode(ChatSession.self, from: data)
            let n = try vault.insertMissingChatSessions([session], origin: "import")
            return n == 0
                ? .duplicate(recordType: "chat_sessions", recordId: session.id.uuidString)
                : .imported(recordType: "chat_sessions", recordId: session.id.uuidString,
                            counts: ["chat_sessions": 1, "chat_messages": session.messages.count], note: nil)
        case "conversation-session":
            return try importWebConversationSession(data)
        case "conversation-memory":
            let payload = try VaultJSON.decoder.decode(ConversationMemoryStorjPayload.self, from: data)
            return try mergeMemory(payload, note: nil)
        case "conversation-history":
            return try importWebConversationHistory(data, raw: text, leftover: &leftover)
        case "merkle-genesis-leaves":
            return try importMerkleLeaves(data)
        case "merkle-genesis-tree", "merkle-genesis-metadata":
            return try importMerkleRoot(data, raw: text, keepPayload: object.dataType == "merkle-genesis-tree", leftover: &leftover)
        default:
            // merkle-genesis (iOS raw file), health-scores, quarterly-aggregate,
            // gut-health-species, merkle-v2-*: no table yet, keep the JSON.
            return .archived(payloadJSON: text)
        }
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

    private func importTimelineEvent(_ data: Data) throws -> Outcome {
        let event = try VaultJSON.decoder.decode(TimelineEvent.self, from: data)
        // Unknown web types decode as CUSTOM; keep the original in event_type.
        let rawType = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["eventType"] as? String
        var row = TimelineEventRow(event: event, origin: "import")
        if let rawType { row.eventType = rawType }
        let inserted: Bool = try vault.dbQueue.write { db in
            if try TimelineEventRow.exists(db, key: row.id) { return false }
            try row.insert(db)
            return true
        }
        guard inserted else { return .duplicate(recordType: "timeline_events", recordId: event.id) }
        let note = rawType.flatMap { TimelineEventType(rawValue: $0) == nil ? "event type \($0) shown as Custom" : nil }
        return .imported(recordType: "timeline_events", recordId: event.id, counts: ["timeline_events": 1], note: note)
    }

    // MARK: - Chat and memory (website shapes)

    private func importWebConversationSession(_ data: Data) throws -> Outcome {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionDict = root["session"] as? [String: Any],
              let rawId = sessionDict["id"] as? String else { throw ImportError.shape("no session") }
        let messages = (root["messages"] as? [[String: Any]] ?? []).enumerated().compactMap { index, m -> ChatMessage? in
            guard let content = m["content"] as? String else { return nil }
            let role = MessageRole(rawValue: m["role"] as? String ?? "") ?? .assistant
            let ts = Self.number(m["timestamp"]).map { Date(unixMillis: Int64($0)) } ?? Date()
            return ChatMessage(id: Self.uuid(from: m["id"] as? String ?? "\(rawId)-\(index)"),
                               role: role, content: content, timestamp: ts)
        }
        let started = Self.number(sessionDict["startedAt"]).map { Date(unixMillis: Int64($0)) } ?? messages.first?.timestamp ?? Date()
        var session = ChatSession(id: Self.uuid(from: rawId), createdAt: started)
        session.messages = messages
        session.updatedAt = messages.last?.timestamp ?? started
        session.healthSummary = sessionDict["summary"] as? String
        let n = try vault.insertMissingChatSessions([session], origin: "import:web")
        return n == 0 ? .duplicate(recordType: "chat_sessions", recordId: session.id.uuidString)
                      : .imported(recordType: "chat_sessions", recordId: session.id.uuidString,
                                  counts: ["chat_sessions": 1, "chat_messages": messages.count], note: nil)
    }

    private func importWebConversationHistory(_ data: Data, raw: String, leftover: inout String?) throws -> Outcome {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ImportError.shape("not an object") }
        var skippedCategories = Set<String>()
        let facts: [CriticalFact] = (root["criticalFacts"] as? [[String: Any]] ?? []).compactMap { f in
            guard let value = f["value"] as? String, let cat = f["category"] as? String else { return nil }
            guard let category = FactCategory(rawValue: cat) else { skippedCategories.insert(cat); return nil }
            let identified = (f["dateIdentified"] as? String).flatMap(VaultJSON.parseISODate) ?? Date()
            return CriticalFact(id: Self.uuid(from: f["id"] as? String ?? value), category: category, value: value,
                                context: f["context"] as? String, dateIdentified: identified,
                                isActive: f["isActive"] as? Bool ?? true, lastConfirmed: nil)
        }
        let summaries: [SessionSummary] = (root["sessions"] as? [[String: Any]] ?? []).compactMap { s in
            guard let summary = s["summary"] as? String, !summary.isEmpty, let rawId = s["id"] as? String else { return nil }
            return SessionSummary(
                id: Self.uuid(from: rawId),
                date: Self.number(s["startedAt"]).map { Date(unixMillis: Int64($0)) } ?? Date(),
                summary: summary, topics: s["topics"] as? [String] ?? [],
                importance: MemoryImportance(rawValue: s["importance"] as? String ?? "") ?? .medium,
                messageCount: Int(Self.number(s["messageCount"]) ?? 0)
            )
        }
        var note: String?
        if !skippedCategories.isEmpty {
            note = "fact categories not in this app kept as JSON: \(skippedCategories.sorted().joined(separator: ", "))"
            leftover = raw
        }
        return try mergeMemory(ConversationMemoryStorjPayload(facts: facts, summaries: summaries), note: note)
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
