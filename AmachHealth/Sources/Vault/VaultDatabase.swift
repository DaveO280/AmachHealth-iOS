// VaultDatabase.swift
// AmachHealth
//
// The on-device vault: one SQLite database per wallet (GRDB).
//
// Encryption at rest: plain GRDB on the system SQLite. GRDB only supports
// SQLCipher through SPM by forking GRDB, so we don't. Instead the vault
// directory, the database and its WAL/SHM files use
// FileProtectionType.complete and are excluded from backup. The HKDF vault
// key (LocalVaultKey) names the file and is checked on open; it is ready to
// become the SQLCipher passphrase later. See PROJECT_STATE.md.
//
// Schema: SCHEMA.md at the repo root. Every change is a new migration below,
// never an edit to an old one.

import Foundation
import GRDB

final class VaultDatabase {
    let dbQueue: DatabaseQueue
    let walletAddress: String
    /// Where this vault keeps files that aren't rows (original lab PDFs).
    let filesDirectory: URL

    /// Highest schema version the migrations below produce.
    static let currentSchemaVersion = 3

    private init(dbQueue: DatabaseQueue, walletAddress: String, filesDirectory: URL) {
        self.dbQueue = dbQueue
        self.walletAddress = walletAddress
        self.filesDirectory = filesDirectory
    }

    // MARK: - Opening

    enum OpenError: LocalizedError {
        case keyMismatch

        var errorDescription: String? {
            switch self {
            case .keyMismatch: return "This vault belongs to a different wallet key"
            }
        }
    }

    /// Open (creating if needed) the vault for this wallet key.
    static func open(key: LocalVaultKey, directory: URL? = nil) throws -> VaultDatabase {
        let dir = try directory ?? defaultDirectory()
        try prepareDirectory(dir)
        let url = dir.appendingPathComponent("vault-\(key.fileIdentifier).sqlite")

        var config = Configuration()
        config.foreignKeysEnabled = true
        config.label = "AmachVault"
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        protectFiles(at: url)

        let files = dir.appendingPathComponent("files-\(key.fileIdentifier)", isDirectory: true)
        let vault = VaultDatabase(dbQueue: queue, walletAddress: key.walletAddress, filesDirectory: files)
        try vault.migrate()
        try vault.verifyKeyCheck(key)
        return vault
    }

    /// In-memory vault for tests and previews.
    static func inMemory(walletAddress: String = "0xtest") throws -> VaultDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let files = FileManager.default.temporaryDirectory.appendingPathComponent("vault-files-\(UUID().uuidString)")
        let vault = VaultDatabase(dbQueue: try DatabaseQueue(configuration: config), walletAddress: walletAddress, filesDirectory: files)
        try vault.migrate()
        return vault
    }

    static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return support.appendingPathComponent("Vault", isDirectory: true)
    }

    static func prepareDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = dir
        try? mutable.setResourceValues(values)
    }

    /// The db, -wal and -shm files: complete protection, no backup.
    static func protectFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: url.path + suffix)
            ProtectedLocalFile.protectExisting(at: fileURL)
        }
    }

    private func verifyKeyCheck(_ key: LocalVaultKey) throws {
        try dbQueue.write { db in
            if let stored = try String.fetchOne(db, sql: "SELECT value FROM vault_meta WHERE key = 'key_check'") {
                guard stored == key.keyCheck else { throw OpenError.keyMismatch }
            } else {
                try db.execute(
                    sql: "INSERT INTO vault_meta (key, value) VALUES ('key_check', ?), ('wallet_address', ?)",
                    arguments: [key.keyCheck, key.walletAddress]
                )
            }
        }
    }

    // MARK: - Meta

    func meta(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM vault_meta WHERE key = ?", arguments: [key])
        }
    }

    func setMeta(_ key: String, _ value: String?) throws {
        try dbQueue.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO vault_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM vault_meta WHERE key = ?", arguments: [key])
            }
        }
    }

    func schemaVersion() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(version) FROM schema_version") ?? 0
        }
    }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: Schema.v1)
            try VaultDatabase.recordSchemaVersion(1, in: db)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: Schema.v2)
            try VaultDatabase.recordSchemaVersion(2, in: db)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: Schema.v3)
            try VaultDatabase.recordSchemaVersion(3, in: db)
        }
        // Future: migrator.registerMigration("v4") { db in ...; recordSchemaVersion(4, in: db) }
        return migrator
    }

    func migrate() throws {
        try Self.migrator.migrate(dbQueue)
    }

    static func recordSchemaVersion(_ version: Int, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
            arguments: [version, Int64(Date().timeIntervalSince1970 * 1000)]
        )
    }
}

// MARK: - Schema v1

extension VaultDatabase {
    enum Schema {
        /// Tables whose rows are backed up. Each gets triggers that bump
        /// backup_state.local_version on insert, update and delete.
        static var backedUpTables: [(table: String, idExpr: (String) -> String)] {
            v1BackedUpTables + v2BackedUpTables
        }

        /// Created by v1. Never edit: v1's SQL is built from this list.
        static let v1BackedUpTables: [(table: String, idExpr: (String) -> String)] = [
            ("daily_metrics", { "\($0).day || '|' || \($0).metric" }),
            ("lab_reports", { "\($0).id" }),
            ("lab_markers", { "CAST(\($0).id AS TEXT)" }),
            ("timeline_events", { "\($0).id" }),
            ("journal_entries", { "\($0).id" }),
            ("chat_sessions", { "\($0).id" }),
            ("chat_messages", { "\($0).id" }),
            ("memory_facts", { "\($0).id" }),
            ("memory_summaries", { "\($0).id" }),
            ("merkle_leaves", { "CAST(\($0).day_id AS TEXT) || '|' || CAST(\($0).leaf_version AS TEXT)" }),
            ("merkle_roots", { "\($0).root" }),
        ]

        static var v1: String {
            tables + v1BackedUpTables.map { triggers(table: $0.table, idExpr: $0.idExpr) }.joined(separator: "\n")
        }

        static let v2BackedUpTables: [(table: String, idExpr: (String) -> String)] = [
            ("lab_pdfs", { "\($0).sha256" }),
            ("storj_imports", { "\($0).object_key" }),
        ]

        /// v2 (Phase 3): original lab PDFs and the local copy of the backup index.
        /// storj_imports gains triggers so archived legacy payloads are backed
        /// up before old Storj objects can be deleted; its existing rows are
        /// queued once here.
        static var v2: String {
            """
            CREATE TABLE lab_pdfs (
                sha256      TEXT PRIMARY KEY NOT NULL,
                report_id   TEXT,
                filename    TEXT,
                byte_count  INTEGER NOT NULL,
                created_at  INTEGER NOT NULL
            );

            CREATE TABLE backup_objects (
                chunk_key   TEXT PRIMARY KEY NOT NULL,
                entry_json  TEXT NOT NULL,
                updated_at  INTEGER NOT NULL
            );

            INSERT INTO backup_state (record_type, record_id, local_version, backed_up_version)
            SELECT 'storj_imports', object_key, 1, 0 FROM storj_imports WHERE true
            ON CONFLICT(record_type, record_id) DO UPDATE SET local_version = local_version + 1;

            """ + v2BackedUpTables.map { triggers(table: $0.table, idExpr: $0.idExpr) }.joined(separator: "\n")
        }

        /// v3: a memory fact drawn from a timeline entry names it, so deleting
        /// or editing the entry retires the fact.
        static let v3 = "ALTER TABLE memory_facts ADD COLUMN source_event_id TEXT;"

        private static func triggers(table: String, idExpr: @escaping (String) -> String) -> String {
            let bump = { (row: String) in
                """
                INSERT INTO backup_state (record_type, record_id, local_version, backed_up_version)
                VALUES ('\(table)', \(idExpr(row)), 1, 0)
                ON CONFLICT(record_type, record_id) DO UPDATE SET local_version = local_version + 1;
                """
            }
            return """
            CREATE TRIGGER \(table)_bump_insert AFTER INSERT ON \(table) BEGIN \(bump("NEW")) END;
            CREATE TRIGGER \(table)_bump_update AFTER UPDATE ON \(table) BEGIN \(bump("NEW")) END;
            CREATE TRIGGER \(table)_bump_delete AFTER DELETE ON \(table) BEGIN \(bump("OLD")) END;
            """
        }

        private static let tables = """
        CREATE TABLE schema_version (
            version     INTEGER NOT NULL,
            applied_at  INTEGER NOT NULL
        );

        CREATE TABLE vault_meta (
            key    TEXT PRIMARY KEY NOT NULL,
            value  TEXT NOT NULL
        );

        CREATE TABLE daily_metrics (
            day         TEXT NOT NULL,
            metric      TEXT NOT NULL,
            total       REAL,
            avg         REAL,
            min         REAL,
            max         REAL,
            count       INTEGER NOT NULL DEFAULT 0,
            source      TEXT NOT NULL,
            sleep_in_bed_min   REAL,
            sleep_awake_min    REAL,
            sleep_core_min     REAL,
            sleep_deep_min     REAL,
            sleep_rem_min      REAL,
            sleep_efficiency   REAL,
            updated_at  INTEGER NOT NULL,
            PRIMARY KEY (day, metric)
        ) WITHOUT ROWID;
        CREATE INDEX daily_metrics_metric_day ON daily_metrics(metric, day);

        CREATE TABLE lab_reports (
            id                 TEXT PRIMARY KEY NOT NULL,
            kind               TEXT NOT NULL CHECK (kind IN ('bloodwork', 'dexa', 'medical')),
            report_date        TEXT,
            laboratory         TEXT,
            source_pdf_sha256  TEXT,
            created_at         INTEGER NOT NULL,
            subtype            TEXT,
            title              TEXT,
            source             TEXT,
            notes              TEXT,
            narrative          TEXT,
            fingerprint        TEXT,
            origin             TEXT NOT NULL,
            storj_key          TEXT,
            attestation_tx_hash TEXT
        );
        CREATE INDEX lab_reports_kind_date ON lab_reports(kind, report_date);
        CREATE UNIQUE INDEX lab_reports_fingerprint ON lab_reports(kind, fingerprint) WHERE fingerprint IS NOT NULL;

        CREATE TABLE lab_markers (
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            report_id        TEXT NOT NULL REFERENCES lab_reports(id) ON DELETE CASCADE,
            position         INTEGER NOT NULL,
            name             TEXT NOT NULL,
            canonical_name   TEXT NOT NULL,
            value            REAL,
            value_text       TEXT,
            unit             TEXT,
            reference_range  TEXT,
            flag             TEXT,
            panel            TEXT
        );
        CREATE INDEX lab_markers_report ON lab_markers(report_id, position);
        CREATE INDEX lab_markers_canonical ON lab_markers(canonical_name);

        CREATE TABLE timeline_events (
            id                  TEXT PRIMARY KEY NOT NULL,
            event_type          TEXT NOT NULL,
            occurred_at         INTEGER NOT NULL,
            data_json           TEXT NOT NULL,
            metadata_json       TEXT NOT NULL,
            anomaly_type        TEXT,
            metric              TEXT,
            direction           TEXT,
            deviation_pct       REAL,
            resolved_at         INTEGER,
            attestation_tx_hash TEXT,
            origin              TEXT NOT NULL,
            updated_at          INTEGER NOT NULL
        );
        CREATE INDEX timeline_events_time ON timeline_events(occurred_at);

        CREATE TABLE journal_entries (
            id          TEXT PRIMARY KEY NOT NULL,
            day         TEXT NOT NULL,
            body        TEXT NOT NULL,
            tags_json   TEXT,
            created_at  INTEGER NOT NULL,
            updated_at  INTEGER NOT NULL
        );
        CREATE INDEX journal_entries_day ON journal_entries(day);

        CREATE TABLE chat_sessions (
            id               TEXT PRIMARY KEY NOT NULL,
            created_at       INTEGER NOT NULL,
            updated_at       INTEGER NOT NULL,
            is_current       INTEGER NOT NULL DEFAULT 0,
            health_summary   TEXT,
            rolling_summary  TEXT,
            storj_uri        TEXT,
            origin           TEXT NOT NULL
        );
        CREATE INDEX chat_sessions_updated ON chat_sessions(updated_at);

        CREATE TABLE chat_messages (
            id             TEXT PRIMARY KEY NOT NULL,
            session_id     TEXT NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
            position       INTEGER NOT NULL,
            role           TEXT NOT NULL,
            content        TEXT NOT NULL,
            created_at     INTEGER NOT NULL,
            metadata_json  TEXT,
            feedback       TEXT
        );
        CREATE INDEX chat_messages_session ON chat_messages(session_id, position);

        CREATE TABLE memory_facts (
            id                 TEXT PRIMARY KEY NOT NULL,
            category           TEXT NOT NULL,
            value              TEXT NOT NULL,
            context            TEXT,
            identified_at      INTEGER NOT NULL,
            last_confirmed_at  INTEGER,
            is_active          INTEGER NOT NULL DEFAULT 1
        );

        CREATE TABLE memory_summaries (
            id             TEXT PRIMARY KEY NOT NULL,
            date           INTEGER NOT NULL,
            summary        TEXT NOT NULL,
            topics_json    TEXT NOT NULL,
            importance     TEXT NOT NULL,
            message_count  INTEGER NOT NULL
        );

        CREATE TABLE merkle_leaves (
            day_id        INTEGER NOT NULL,
            leaf_version  INTEGER NOT NULL,
            fields        TEXT NOT NULL,
            hash          TEXT NOT NULL,
            PRIMARY KEY (day_id, leaf_version)
        ) WITHOUT ROWID;

        CREATE TABLE merkle_roots (
            root        TEXT PRIMARY KEY NOT NULL,
            start_day   INTEGER NOT NULL,
            end_day     INTEGER NOT NULL,
            tx_hash     TEXT,
            leaf_count  INTEGER,
            tree_depth  INTEGER,
            created_at  INTEGER NOT NULL
        );

        CREATE TABLE backup_state (
            record_type        TEXT NOT NULL,
            record_id          TEXT NOT NULL,
            local_version      INTEGER NOT NULL,
            backed_up_version  INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (record_type, record_id)
        ) WITHOUT ROWID;
        CREATE INDEX backup_state_pending ON backup_state(record_type) WHERE local_version > backed_up_version;

        CREATE TABLE healthkit_sync (
            stream           TEXT PRIMARY KEY NOT NULL,
            anchor           BLOB,
            backfilled_from  TEXT,
            earliest_day     TEXT,
            updated_at       INTEGER NOT NULL
        );

        CREATE TABLE storj_imports (
            object_key   TEXT PRIMARY KEY NOT NULL,
            data_type    TEXT NOT NULL,
            uploaded_at  INTEGER NOT NULL,
            size         INTEGER NOT NULL,
            status       TEXT NOT NULL CHECK (status IN ('imported', 'duplicate', 'archived', 'failed')),
            record_type  TEXT,
            record_id    TEXT,
            detail       TEXT,
            payload_json TEXT,
            imported_at  INTEGER NOT NULL
        );

        """
    }
}

// MARK: - Small helpers shared by the stores

extension Date {
    var unixMillis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(unixMillis: Int64) {
        self.init(timeIntervalSince1970: Double(unixMillis) / 1000)
    }

    /// Local calendar day, "yyyy-MM-dd". Same rule as Date.dateKey.
    var vaultDay: String { VaultDay.formatter.string(from: self) }
}

enum VaultDay {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date? { formatter.date(from: day) }
}
