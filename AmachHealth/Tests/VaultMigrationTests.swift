// VaultMigrationTests.swift
// AmachHealthTests
//
// Schema v1, migrations, backup_state triggers, on-disk open/reopen, and the
// one-time move of pre-vault JSON / UserDefaults data.

import XCTest
import GRDB
@testable import AmachHealth

final class VaultMigrationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func walletKey(_ hex: String = WalletDecryptorFixtures.encryptionKey) -> WalletEncryptionKey {
        WalletEncryptionKey(walletAddress: WalletDecryptorFixtures.walletAddress, encryptionKey: hex, signature: "0x", timestamp: 0)
    }

    // MARK: - Schema

    func test_migrations_create_every_table_and_record_version() throws {
        let vault = try VaultDatabase.inMemory()
        XCTAssertEqual(try vault.schemaVersion(), 3)
        XCTAssertEqual(VaultDatabase.currentSchemaVersion, 3)
        let tables = try vault.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        for table in [
            "schema_version", "vault_meta", "daily_metrics", "lab_reports", "lab_markers",
            "timeline_events", "journal_entries", "chat_sessions", "chat_messages",
            "memory_facts", "memory_summaries", "merkle_leaves", "merkle_roots",
            "backup_state", "healthkit_sync", "storj_imports",
            "lab_pdfs", "backup_objects",
        ] {
            XCTAssertTrue(tables.contains(table), "missing \(table)")
        }
    }

    func test_migrator_is_idempotent_and_every_version_is_registered() throws {
        let vault = try VaultDatabase.inMemory()
        try vault.migrate()
        try vault.migrate()
        XCTAssertEqual(try vault.schemaVersion(), 3)
        let applied = try vault.dbQueue.read { db in try VaultDatabase.migrator.appliedIdentifiers(db) }
        XCTAssertEqual(applied, ["v1", "v2", "v3"])
        XCTAssertEqual(try vault.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_version") }, 3)
    }

    func test_v2_on_a_v1_vault_queues_existing_storj_imports_for_backup() throws {
        let queue = try DatabaseQueue()
        var v1Only = DatabaseMigrator()
        v1Only.registerMigration("v1") { db in
            try db.execute(sql: VaultDatabase.Schema.v1)
            try VaultDatabase.recordSchemaVersion(1, in: db)
        }
        try v1Only.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO storj_imports (object_key, data_type, uploaded_at, size, status, imported_at)
                VALUES ('timeline-event/1-a.enc', 'timeline-event', 1, 10, 'archived', 2)
                """)
        }
        try VaultDatabase.migrator.migrate(queue)
        let pending = try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT local_version - backed_up_version FROM backup_state
                WHERE record_type = 'storj_imports' AND record_id = 'timeline-event/1-a.enc'
                """)
        }
        XCTAssertEqual(pending, 1)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO lab_pdfs (sha256, byte_count, created_at) VALUES ('ab', 3, 0)")
        }
        let pdfVersion = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT local_version FROM backup_state WHERE record_type = 'lab_pdfs' AND record_id = 'ab'")
        }
        XCTAssertEqual(pdfVersion, 1)
    }

    func test_lab_kind_is_constrained() throws {
        let vault = try VaultDatabase.inMemory()
        XCTAssertThrowsError(try vault.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO lab_reports (id, kind, created_at, origin) VALUES ('x', 'urine', 0, 'test')")
        })
    }

    func test_backup_state_bumps_on_insert_update_delete() throws {
        let vault = try VaultDatabase.inMemory()
        let row = DailyMetricRow(day: "2025-10-01", metric: "steps", total: 100, count: 1, source: .healthKit)
        try vault.upsertDailyMetrics([row], policy: .overwrite)
        func version() throws -> Int? {
            try vault.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT local_version FROM backup_state WHERE record_type = 'daily_metrics' AND record_id = '2025-10-01|steps'")
            }
        }
        XCTAssertEqual(try version(), 1)
        var updated = row
        updated.total = 200
        try vault.upsertDailyMetrics([updated], policy: .overwrite)
        XCTAssertEqual(try version(), 2)
        _ = try vault.dbQueue.write { db in try DailyMetricRow.deleteAll(db) }
        XCTAssertEqual(try version(), 3, "deletes bump too, so Phase 3 can back up tombstones")
        let backedUp = try vault.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT backed_up_version FROM backup_state WHERE record_id = '2025-10-01|steps'")
        }
        XCTAssertEqual(backedUp, 0)
    }

    func test_unchanged_chat_saves_do_not_bump_backup_state() throws {
        let vault = try VaultDatabase.inMemory()
        var session = ChatSession()
        session.messages = [ChatMessage(role: .user, content: "hi")]
        try vault.saveChatSessions([session], currentId: session.id)
        let before = try vault.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT SUM(local_version) FROM backup_state") }
        try vault.saveChatSessions([session], currentId: session.id)
        let after = try vault.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT SUM(local_version) FROM backup_state") }
        XCTAssertEqual(before, after)
    }

    // MARK: - On-disk vault

    func test_open_creates_protected_file_and_reopens_with_same_key() throws {
        let key = try LocalVaultKey(walletKey: walletKey())
        do {
            let vault = try VaultDatabase.open(key: key, directory: tempDir)
            try vault.upsertDailyMetrics([DailyMetricRow(day: "2025-10-01", metric: "steps", total: 5, count: 1, source: .healthKit)],
                                         policy: .overwrite)
        }
        let file = tempDir.appendingPathComponent("vault-\(key.fileIdentifier).sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)

        let reopened = try VaultDatabase.open(key: key, directory: tempDir)
        XCTAssertEqual(try reopened.dailyMetric(metric: "steps", day: "2025-10-01")?.total, 5)
        XCTAssertEqual(try reopened.schemaVersion(), 3)
    }

    func test_vault_file_with_wrong_key_check_refuses_to_open() throws {
        let key = try LocalVaultKey(walletKey: walletKey())
        _ = try VaultDatabase.open(key: key, directory: tempDir)
        // Tamper: pretend the file was created by another key.
        let file = tempDir.appendingPathComponent("vault-\(key.fileIdentifier).sqlite")
        let queue = try DatabaseQueue(path: file.path)
        try queue.write { db in try db.execute(sql: "UPDATE vault_meta SET value = 'other' WHERE key = 'key_check'") }
        try queue.close()
        XCTAssertThrowsError(try VaultDatabase.open(key: key, directory: tempDir)) { error in
            guard case VaultDatabase.OpenError.keyMismatch = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: - Legacy local data

    func test_chat_file_is_imported_verified_and_deleted() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("amach_chat_sessions.json")
        var current = ChatSession()
        current.messages = [ChatMessage(role: .user, content: "current q"), ChatMessage(role: .assistant, content: "a")]
        var old = ChatSession(createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        old.messages = [ChatMessage(role: .user, content: "old q")]
        // Old builds used JSONEncoder's default date encoding.
        try JSONEncoder().encode([current, old]).write(to: url)

        let vault = try VaultDatabase.inMemory()
        XCTAssertTrue(LegacyLocalDataMigration.migrateChat(into: vault, from: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let loaded = try vault.loadChatSessions(recentLimit: 10)
        XCTAssertEqual(loaded.current?.id, current.id)
        XCTAssertEqual(loaded.current?.messages.map(\.content), ["current q", "a"])
        XCTAssertEqual(loaded.recent.map(\.id), [old.id])
        XCTAssertEqual(loaded.recent.first?.createdAt.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.01)
    }

    func test_unreadable_chat_file_is_kept() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("amach_chat_sessions.json")
        try Data("not json".utf8).write(to: url)
        let vault = try VaultDatabase.inMemory()
        XCTAssertFalse(LegacyLocalDataMigration.migrateChat(into: vault, from: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_memory_file_and_timeline_cache_move_into_vault() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent("amach_conversation_memory.json")
        let fact = CriticalFact(id: UUID(), category: .medication, value: "Metformin 500mg", context: nil,
                                dateIdentified: Date(timeIntervalSince1970: 1_700_000_000), isActive: true, lastConfirmed: nil)
        try JSONEncoder().encode(ConversationMemoryStorjPayload(facts: [fact], summaries: [])).write(to: url)

        let vault = try VaultDatabase.inMemory()
        XCTAssertTrue(LegacyLocalDataMigration.migrateMemory(into: vault, from: url))
        XCTAssertEqual(try vault.loadMemory().facts.map(\.value), ["Metformin 500mg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "vault-tests-\(UUID().uuidString)"))
        let event = TimelineEvent(id: "e1", eventType: .medicationStarted, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                  data: ["name": "Metformin"], metadata: TimelineEventMetadata(platform: "ios", version: "1", source: .userEntered))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode([event]), forKey: LegacyLocalDataMigration.timelineDefaultsKey)
        XCTAssertTrue(LegacyLocalDataMigration.migrateTimeline(into: vault, defaults: defaults))
        XCTAssertEqual(try vault.timelineEvents().map(\.id), ["e1"])
        XCTAssertNil(defaults.data(forKey: LegacyLocalDataMigration.timelineDefaultsKey))
    }

    // MARK: - Stores

    func test_lab_report_roundtrip_and_fingerprint_dedupe() throws {
        let vault = try VaultDatabase.inMemory()
        let dexa = DexaReportData(
            type: "dexa", source: "BodySpec", scanDate: "2025-08-20", totalBodyFatPercent: 18.4, totalLeanMassKg: 61.2,
            visceralFatRating: nil, visceralFatAreaCm2: 70, visceralFatVolumeCm3: nil,
            boneDensityTotal: DexaBoneDensityTotal(bmd: 1.2, tScore: 0.8, zScore: 0.6), androidGynoidRatio: 0.9,
            regions: [DexaRegionMetrics(region: "Left Arm", bodyFatPercent: 14, leanMassKg: 3.4, fatMassKg: 0.6,
                                        boneDensityGPerCm2: nil, tScore: nil, zScore: nil)],
            notes: nil, rawText: "", confidence: 0.8
        )
        let item = LabVaultMapping.dexa(dexa, id: "d1", origin: "device")
        XCTAssertEqual(try vault.saveLabReport(item), .inserted("d1"))
        XCTAssertEqual(try vault.saveLabReport(LabVaultMapping.dexa(dexa, id: "d2", origin: "device")), .duplicate("d1"))

        let stored = try XCTUnwrap(try vault.labReport(id: "d1"))
        XCTAssertEqual(stored.asDexa.totalBodyFatPercent, 18.4)
        XCTAssertEqual(stored.asDexa.boneDensityTotal?.tScore, 0.8)
        XCTAssertEqual(stored.dexaRegions.map(\.region), ["left_arm"])
        XCTAssertEqual(stored.dexaRegions.first?.markers.count, 3, "regional values are kept, not dropped")
    }

    func test_imports_never_overwrite_healthkit_rows() throws {
        let vault = try VaultDatabase.inMemory()
        try vault.upsertDailyMetrics([DailyMetricRow(day: "2025-10-01", metric: "steps", total: 100, count: 1, source: .healthKit)], policy: .overwrite)
        let written = try vault.upsertDailyMetrics([
            DailyMetricRow(day: "2025-10-01", metric: "steps", total: 999, count: 1, source: .importIOS),
            DailyMetricRow(day: "2025-09-30", metric: "steps", total: 50, count: 1, source: .importIOS),
        ], policy: .fillImportedOnly)
        XCTAssertEqual(written, 1)
        XCTAssertEqual(try vault.dailyMetric(metric: "steps", day: "2025-10-01")?.total, 100)
        XCTAssertEqual(try vault.dailyMetric(metric: "steps", day: "2025-09-30")?.total, 50)
    }
}
