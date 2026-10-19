// BackupFormat.swift
// AmachHealth
//
// Backup format v1: what goes in each object and in the index
// (BACKUP-FORMAT.md). Rows are stored with SCHEMA.md's table and column
// names, so the backup is the vault schema, not an app-specific encoding.

import Foundation
import GRDB

// MARK: - Index

/// One chunk of vault data (a month of metrics, a lab report, a chat
/// session, ...) stored as one or more encrypted parts.
struct BackupChunkEntry: Codable, Equatable {
    struct Part: Codable, Equatable {
        let id: String
        let sha256: String
        let size: Int
    }

    enum Kind: String, Codable {
        case rows   // JSON of table rows (BackupChunkPayload)
        case blob   // raw bytes (an original PDF)
    }

    let key: String
    let kind: Kind
    let tables: [String]
    /// "YYYY-MM" for monthly chunks, "YYYY" for yearly ones.
    let month: String?
    /// "table|id" for every record in the chunk. Omitted for chunks whose
    /// records name the chunk themselves (daily_metrics, merkle_leaves).
    let recordIds: [String]?
    /// Bumped each time the chunk is re-uploaded.
    let version: Int
    /// SHA-256 of the whole plaintext (all parts joined).
    let sha256: String
    let size: Int
    let parts: [Part]
}

/// The decrypted body of the index: every chunk in the backup.
struct BackupIndexBody: Codable, Equatable {
    var chunks: [BackupChunkEntry]
}

/// The root object, stored at BackupKey.indexObjectId. Small; points at the
/// body, which is split into parts like any other large object.
struct BackupIndexRoot: Codable, Equatable {
    static let format = "amach-backup-index"

    var format: String = BackupIndexRoot.format
    var version: Int = 1
    var schemaVersion: Int
    var generation: Int
    var updatedAt: Int64
    var body: [BackupChunkEntry.Part]
    var bodySha256: String
}

/// Plaintext of a `rows` chunk.
struct BackupChunkPayload: Codable, Equatable {
    static let format = "amach-backup-chunk"

    struct TableRows: Codable, Equatable {
        let columns: [String]
        let rows: [[BackupValue]]
    }

    var format: String = BackupChunkPayload.format
    var version: Int = 1
    var schemaVersion: Int
    var chunk: String
    var tables: [String: TableRows]
}

/// An SQLite value. JSON: null, number, string, or {"b64": "..."} for blobs.
enum BackupValue: Codable, Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(_ value: DatabaseValue) {
        switch value.storage {
        case .null: self = .null
        case .int64(let v): self = .int(v)
        case .double(let v): self = .real(v)
        case .string(let v): self = .text(v)
        case .blob(let v): self = .blob(v)
        }
    }

    var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .int(let v): return v.databaseValue
        case .real(let v): return v.databaseValue
        case .text(let v): return v.databaseValue
        case .blob(let v): return v.databaseValue
        }
    }

    private struct Blob: Codable { let b64: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .real(v) }
        else if let v = try? c.decode(String.self) { self = .text(v) }
        else {
            let blob = try c.decode(Blob.self)
            guard let data = Data(base64Encoded: blob.b64) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad base64")
            }
            self = .blob(data)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .int(let v): try c.encode(v)
        case .real(let v): try c.encode(v)
        case .text(let v): try c.encode(v)
        case .blob(let v): try c.encode(Blob(b64: v.base64EncodedString()))
        }
    }
}

enum BackupJSON {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
    static let decoder = JSONDecoder()
}

// MARK: - Chunk keys

/// Which chunk a record lives in. Chunk keys appear only inside the
/// encrypted index; object names are random.
enum BackupChunkKey {
    /// Keep every object well under Storj's 4 MB comfort line.
    static let maxPartBytes = 3 * 1024 * 1024

    static func dailyMetrics(month: String) -> String { "daily_metrics/\(month)" }
    static func labReport(_ id: String) -> String { "lab_report/\(id)" }
    static func timeline(month: String) -> String { "timeline/\(month)" }
    static func journal(month: String) -> String { "journal/\(month)" }
    static func chatSession(_ id: String) -> String { "chat_session/\(id)" }
    static let memory = "memory"
    static func merkleLeaves(year: String) -> String { "merkle_leaves/\(year)" }
    static let merkleRoots = "merkle_roots"
    static let labPdfs = "lab_pdfs"
    static func pdf(_ sha256: String) -> String { "pdf/\(sha256)" }
    static let storjImports = "storj_imports"

    /// UTC month of a Unix-millisecond timestamp.
    static func utcMonth(millis: Int64) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date(unixMillis: millis))
    }

    /// UTC year of a day id (days since the Unix epoch).
    static func utcYear(dayId: Int64) -> String {
        String(utcMonth(millis: dayId * 86_400_000).prefix(4))
    }

    /// UTC [start, end) millis for "YYYY-MM".
    static func monthRange(_ month: String) -> (Int64, Int64)? {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let start = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let end = cal.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start.unixMillis, end.unixMillis)
    }

    /// Day ids [start, end) for a UTC year.
    static func yearDayRange(_ year: String) -> (Int64, Int64)? {
        guard let y = Int(year) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let start = cal.date(from: DateComponents(year: y, month: 1, day: 1)),
              let end = cal.date(from: DateComponents(year: y + 1, month: 1, day: 1)) else { return nil }
        return (start.unixMillis / 86_400_000, end.unixMillis / 86_400_000)
    }

    /// Chunks a record belongs to now, from its live row. A deleted record
    /// has no row; the caller also checks where the index last put it.
    static func liveChunks(recordType: String, recordId: String, db: Database) throws -> [String] {
        switch recordType {
        case "daily_metrics":
            return [dailyMetrics(month: String(recordId.prefix(7)))]
        case "lab_reports":
            return [labReport(recordId)]
        case "lab_markers":
            guard let id = Int64(recordId),
                  let report = try String.fetchOne(db, sql: "SELECT report_id FROM lab_markers WHERE id = ?", arguments: [id])
            else { return [] }
            return [labReport(report)]
        case "timeline_events":
            guard let at = try Int64.fetchOne(db, sql: "SELECT occurred_at FROM timeline_events WHERE id = ?", arguments: [recordId])
            else { return [] }
            return [timeline(month: utcMonth(millis: at))]
        case "journal_entries":
            guard let day = try String.fetchOne(db, sql: "SELECT day FROM journal_entries WHERE id = ?", arguments: [recordId])
            else { return [] }
            return [journal(month: String(day.prefix(7)))]
        case "chat_sessions":
            return [chatSession(recordId)]
        case "chat_messages":
            guard let session = try String.fetchOne(db, sql: "SELECT session_id FROM chat_messages WHERE id = ?", arguments: [recordId])
            else { return [] }
            return [chatSession(session)]
        case "memory_facts", "memory_summaries":
            return [memory]
        case "merkle_leaves":
            guard let dayId = recordId.split(separator: "|").first.flatMap({ Int64($0) }) else { return [] }
            return [merkleLeaves(year: utcYear(dayId: dayId))]
        case "merkle_roots":
            return [merkleRoots]
        case "lab_pdfs":
            return [labPdfs, pdf(recordId)]
        case "storj_imports":
            return [storjImports]
        default:
            return []
        }
    }

    /// Record id as backup_state writes it (VaultDatabase.Schema.backedUpTables).
    static func recordId(table: String, row: [String: DatabaseValue]) -> String? {
        func text(_ c: String) -> String? {
            switch row[c]?.storage {
            case .string(let s): return s
            case .int64(let i): return String(i)
            case .double(let d): return String(d)
            default: return nil
            }
        }
        switch table {
        case "daily_metrics":
            guard let d = text("day"), let m = text("metric") else { return nil }
            return "\(d)|\(m)"
        case "merkle_leaves":
            guard let d = text("day_id"), let v = text("leaf_version") else { return nil }
            return "\(d)|\(v)"
        case "merkle_roots": return text("root")
        case "lab_pdfs": return text("sha256")
        case "storj_imports": return text("object_key")
        default: return text("id")
        }
    }
}

// MARK: - Building chunks from the vault

/// A chunk's plaintext plus the records it covers, read in one transaction.
struct BackupChunkSnapshot {
    let key: String
    let kind: BackupChunkEntry.Kind
    let tables: [String]
    let month: String?
    let recordIds: [String]
    let listRecordIds: Bool
    /// nil when the chunk has no rows left (it is removed from the backup).
    let plaintext: Data?
}

extension VaultDatabase {

    /// Parent tables first so restores satisfy foreign keys.
    static let backupTableOrder = [
        "daily_metrics", "lab_reports", "lab_markers", "timeline_events", "journal_entries",
        "chat_sessions", "chat_messages", "memory_facts", "memory_summaries",
        "merkle_leaves", "merkle_roots", "lab_pdfs", "storj_imports",
    ]

    var pdfDirectory: URL { filesDirectory.appendingPathComponent("pdfs", isDirectory: true) }

    func pdfURL(sha256: String) -> URL { pdfDirectory.appendingPathComponent("\(sha256).pdf") }

    /// Every chunk the vault's rows fill today (for a first, full backup).
    func allBackupChunkKeys(_ db: Database) throws -> Set<String> {
        var keys = Set<String>()
        for m in try String.fetchAll(db, sql: "SELECT DISTINCT substr(day, 1, 7) FROM daily_metrics") {
            keys.insert(BackupChunkKey.dailyMetrics(month: m))
        }
        for id in try String.fetchAll(db, sql: "SELECT id FROM lab_reports") { keys.insert(BackupChunkKey.labReport(id)) }
        for at in try Int64.fetchAll(db, sql: "SELECT occurred_at FROM timeline_events") {
            keys.insert(BackupChunkKey.timeline(month: BackupChunkKey.utcMonth(millis: at)))
        }
        for m in try String.fetchAll(db, sql: "SELECT DISTINCT substr(day, 1, 7) FROM journal_entries") {
            keys.insert(BackupChunkKey.journal(month: m))
        }
        for id in try String.fetchAll(db, sql: "SELECT id FROM chat_sessions") { keys.insert(BackupChunkKey.chatSession(id)) }
        if try Int.fetchOne(db, sql: "SELECT (SELECT COUNT(*) FROM memory_facts) + (SELECT COUNT(*) FROM memory_summaries)") ?? 0 > 0 {
            keys.insert(BackupChunkKey.memory)
        }
        for d in try Int64.fetchAll(db, sql: "SELECT DISTINCT day_id FROM merkle_leaves") {
            keys.insert(BackupChunkKey.merkleLeaves(year: BackupChunkKey.utcYear(dayId: d)))
        }
        if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM merkle_roots") ?? 0 > 0 { keys.insert(BackupChunkKey.merkleRoots) }
        let pdfs = try String.fetchAll(db, sql: "SELECT sha256 FROM lab_pdfs")
        if !pdfs.isEmpty { keys.insert(BackupChunkKey.labPdfs) }
        for sha in pdfs { keys.insert(BackupChunkKey.pdf(sha)) }
        if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM storj_imports") ?? 0 > 0 { keys.insert(BackupChunkKey.storjImports) }
        return keys
    }

    /// Read one chunk. Rows are ordered by primary key so unchanged data
    /// produces identical bytes (and is not re-uploaded).
    func backupSnapshot(chunk key: String, _ db: Database) throws -> BackupChunkSnapshot {
        let (head, arg) = Self.splitChunkKey(key)
        var queries: [(table: String, sql: String, args: StatementArguments)] = []
        var month: String?
        var listIds = true

        switch head {
        case "daily_metrics":
            month = arg
            listIds = false
            queries = [("daily_metrics", "SELECT * FROM daily_metrics WHERE day >= ? AND day < ? ORDER BY day, metric",
                        [arg + "-01", arg + "-32"])]
        case "lab_report":
            queries = [
                ("lab_reports", "SELECT * FROM lab_reports WHERE id = ?", [arg]),
                ("lab_markers", "SELECT * FROM lab_markers WHERE report_id = ? ORDER BY id", [arg]),
            ]
        case "timeline":
            month = arg
            let (start, end) = BackupChunkKey.monthRange(arg) ?? (0, 0)
            queries = [("timeline_events", "SELECT * FROM timeline_events WHERE occurred_at >= ? AND occurred_at < ? ORDER BY id",
                        [start, end])]
        case "journal":
            month = arg
            queries = [("journal_entries", "SELECT * FROM journal_entries WHERE day >= ? AND day < ? ORDER BY id",
                        [arg + "-01", arg + "-32"])]
        case "chat_session":
            queries = [
                ("chat_sessions", "SELECT * FROM chat_sessions WHERE id = ?", [arg]),
                ("chat_messages", "SELECT * FROM chat_messages WHERE session_id = ? ORDER BY id", [arg]),
            ]
        case "memory":
            queries = [
                ("memory_facts", "SELECT * FROM memory_facts ORDER BY id", []),
                ("memory_summaries", "SELECT * FROM memory_summaries ORDER BY id", []),
            ]
        case "merkle_leaves":
            month = arg
            listIds = false
            let (start, end) = BackupChunkKey.yearDayRange(arg) ?? (0, 0)
            queries = [("merkle_leaves", "SELECT * FROM merkle_leaves WHERE day_id >= ? AND day_id < ? ORDER BY day_id, leaf_version",
                        [start, end])]
        case "merkle_roots":
            queries = [("merkle_roots", "SELECT * FROM merkle_roots ORDER BY root", [])]
        case "lab_pdfs":
            queries = [("lab_pdfs", "SELECT * FROM lab_pdfs ORDER BY sha256", [])]
        case "storj_imports":
            queries = [("storj_imports", "SELECT * FROM storj_imports ORDER BY object_key", [])]
        case "pdf":
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM lab_pdfs WHERE sha256 = ?)", arguments: [arg]) ?? false
            let bytes = exists ? try? Data(contentsOf: pdfURL(sha256: arg)) : nil
            return BackupChunkSnapshot(key: key, kind: .blob, tables: [], month: nil,
                                       recordIds: ["lab_pdfs|\(arg)"], listRecordIds: true, plaintext: bytes)
        default:
            return BackupChunkSnapshot(key: key, kind: .rows, tables: [], month: nil, recordIds: [], listRecordIds: true, plaintext: nil)
        }

        var tables: [String: BackupChunkPayload.TableRows] = [:]
        var recordIds: [String] = []
        for q in queries {
            let rows = try Row.fetchAll(db, sql: q.sql, arguments: q.args)
            guard let first = rows.first else { continue }
            let columns = Array(first.columnNames)
            var encoded: [[BackupValue]] = []
            encoded.reserveCapacity(rows.count)
            for row in rows {
                var values: [BackupValue] = []
                var dict: [String: DatabaseValue] = [:]
                for (column, value) in row {
                    values.append(BackupValue(value))
                    dict[column] = value
                }
                encoded.append(values)
                if let id = BackupChunkKey.recordId(table: q.table, row: dict) {
                    recordIds.append("\(q.table)|\(id)")
                }
            }
            tables[q.table] = .init(columns: columns, rows: encoded)
        }
        let tableNames = queries.map(\.table)
        guard !tables.isEmpty else {
            return BackupChunkSnapshot(key: key, kind: .rows, tables: tableNames, month: month,
                                       recordIds: [], listRecordIds: listIds, plaintext: nil)
        }
        let payload = BackupChunkPayload(schemaVersion: Self.currentSchemaVersion, chunk: key, tables: tables)
        return BackupChunkSnapshot(key: key, kind: .rows, tables: tableNames, month: month,
                                   recordIds: recordIds, listRecordIds: listIds,
                                   plaintext: try BackupJSON.encoder.encode(payload))
    }

    static func splitChunkKey(_ key: String) -> (String, String) {
        guard let slash = key.firstIndex(of: "/") else { return (key, "") }
        return (String(key[..<slash]), String(key[key.index(after: slash)...]))
    }

    // MARK: - Applying chunks on restore

    struct RestoreOutcome {
        /// Every row went in (nothing local was kept instead).
        var complete = true
        var insertedRecordIds: [(table: String, id: String)] = []
    }

    /// Insert a chunk's rows. Rows already on this phone win: a restore never
    /// overwrites local data, and the chunk is then left pending so the
    /// next backup re-uploads the merged result.
    func applyBackupRows(_ payload: BackupChunkPayload, _ db: Database) throws -> RestoreOutcome {
        guard payload.format == BackupChunkPayload.format else {
            throw BackupError.malformed("unknown chunk format \(payload.format)")
        }
        guard payload.schemaVersion <= Self.currentSchemaVersion else {
            throw BackupError.newerSchema(payload.schemaVersion)
        }
        var outcome = RestoreOutcome()
        let liveColumns = try Dictionary(uniqueKeysWithValues: Self.backupTableOrder.map { table in
            (table, Set(try db.columns(in: table).map(\.name)))
        })
        var skippedParents: [String: Set<String>] = [:]   // parent table → ids kept local

        for table in Self.backupTableOrder {
            guard let data = payload.tables[table], let known = liveColumns[table] else { continue }
            // Columns this app doesn't know are dropped (older app, newer backup
            // of the same schema version can't happen; this guards hand edits).
            let keep = data.columns.enumerated().filter { known.contains($0.element) }
            guard !keep.isEmpty else { continue }
            let columnList = keep.map { "\"\($0.element)\"" }.joined(separator: ", ")
            let placeholders = Array(repeating: "?", count: keep.count).joined(separator: ", ")
            let sql = "INSERT OR IGNORE INTO \(table) (\(columnList)) VALUES (\(placeholders))"
            let statement = try db.cachedStatement(sql: sql)

            for row in data.rows {
                var dict: [String: DatabaseValue] = [:]
                var values: [DatabaseValue] = []
                for (index, column) in keep {
                    let value = index < row.count ? row[index].databaseValue : .null
                    dict[column] = value
                    values.append(value)
                }
                // Children of a parent that stayed local are skipped with it.
                if table == "lab_markers", let parent = String.fromDatabaseValue(dict["report_id"] ?? .null),
                   skippedParents["lab_reports"]?.contains(parent) == true { continue }
                if table == "chat_messages", let parent = String.fromDatabaseValue(dict["session_id"] ?? .null),
                   skippedParents["chat_sessions"]?.contains(parent) == true { continue }
                // Only one open chat session per vault.
                if table == "chat_sessions", let i = keep.firstIndex(where: { $0.element == "is_current" }),
                   values[i] == 1.databaseValue,
                   try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chat_sessions WHERE is_current = 1)") == true {
                    values[i] = 0.databaseValue
                }

                try statement.execute(arguments: StatementArguments(values))
                let id = BackupChunkKey.recordId(table: table, row: dict)
                if db.changesCount > 0 {
                    if let id { outcome.insertedRecordIds.append((table, id)) }
                } else {
                    outcome.complete = false
                    if let id, table == "lab_reports" || table == "chat_sessions" {
                        skippedParents[table, default: []].insert(id)
                    }
                }
            }
        }
        return outcome
    }

    /// Write a restored PDF if this phone doesn't have it. Checks the hash.
    func applyBackupPdf(sha256: String, bytes: Data) throws {
        guard BackupKey.sha256Hex(bytes) == sha256 else { throw BackupError.malformed("PDF hash mismatch") }
        try writeLabPdfFile(sha256: sha256, bytes: bytes)
    }

    func writeLabPdfFile(sha256: String, bytes: Data) throws {
        let url = pdfURL(sha256: sha256)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try Self.prepareDirectory(filesDirectory)
        try Self.prepareDirectory(pdfDirectory)
        try ProtectedLocalFile.write(bytes, to: url)
    }
}

enum BackupError: LocalizedError {
    case malformed(String)
    case newerSchema(Int)
    case missingObject(String)
    case hashMismatch(String)
    case noBackup
    case notConfigured(String)
    case walletUnavailable

    var errorDescription: String? {
        switch self {
        case .malformed(let why): return "The backup couldn't be read (\(why))"
        case .newerSchema(let v): return "This backup was made by a newer version of Amach (schema \(v)). Update the app to restore it."
        case .missingObject: return "Part of the backup is missing"
        case .hashMismatch: return "Part of the backup didn't match its checksum"
        case .noBackup: return "No encrypted backup was found for this wallet"
        case .notConfigured(let why): return why
        case .walletUnavailable: return "Connect your wallet to use encrypted backup"
        }
    }
}
