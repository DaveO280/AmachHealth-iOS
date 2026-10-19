// BackupEngineTests.swift
// AmachHealthTests
//
// Backup → wipe → restore on in-memory vaults with an in-memory transport:
// every backed-up table comes back identical, objects are opaque, backups
// are incremental and crash-safe, and restore never overwrites local data.

import XCTest
import GRDB
import CryptoKit
@testable import AmachHealth

final class BackupEngineTests: XCTestCase {

    private let key = BackupKey(symmetricKey: SymmetricKey(data: Data(repeating: 7, count: 32)))

    // MARK: - Seed

    private func seededVault() throws -> VaultDatabase {
        let vault = try VaultDatabase.inMemory()
        try vault.dbQueue.write { db in
            for (day, steps) in [("2026-08-30", 9100.0), ("2026-09-01", 8000.0), ("2026-09-02", 10500.0), ("2026-10-01", 7000.0)] {
                try db.execute(sql: """
                    INSERT INTO daily_metrics (day, metric, total, count, source, updated_at)
                    VALUES (?, 'steps', ?, 12, 'healthkit', 1)
                    """, arguments: [day, steps])
            }
            try db.execute(sql: """
                INSERT INTO daily_metrics (day, metric, total, count, source, sleep_deep_min, sleep_efficiency, updated_at)
                VALUES ('2026-09-01', 'sleep', 431.5, 3, 'healthkit', 62.25, 0.93, 2)
                """)
            try db.execute(sql: """
                INSERT INTO lab_reports (id, kind, report_date, laboratory, created_at, title, origin, fingerprint)
                VALUES ('bloodwork-1', 'bloodwork', '2026-07-14', 'Quest Diagnostics', 10, 'Annual panel', 'device', 'fp1')
                """)
            try db.execute(sql: """
                INSERT INTO lab_markers (report_id, position, name, canonical_name, value, unit, flag)
                VALUES ('bloodwork-1', 0, 'LDL Cholesterol', 'ldl_cholesterol', 131, 'mg/dL', 'high'),
                       ('bloodwork-1', 1, 'HbA1c', 'hba1c', 5.4, '%', 'normal')
                """)
            try db.execute(sql: """
                INSERT INTO timeline_events (id, event_type, occurred_at, data_json, metadata_json, origin, updated_at)
                VALUES ('evt-1', 'MEDICATION_STARTED', 1783000000000, '{"name":"Metformin"}', '{"platform":"ios"}', 'device', 1)
                """)
            try db.execute(sql: """
                INSERT INTO journal_entries (id, day, body, created_at, updated_at)
                VALUES ('j1', '2026-09-03', 'Slept badly after late coffee', 1, 1)
                """)
            try db.execute(sql: """
                INSERT INTO chat_sessions (id, created_at, updated_at, is_current, origin)
                VALUES ('11111111-1111-1111-1111-111111111111', 1, 2, 1, 'device')
                """)
            try db.execute(sql: """
                INSERT INTO chat_messages (id, session_id, position, role, content, created_at)
                VALUES ('m1', '11111111-1111-1111-1111-111111111111', 0, 'user', 'Why is my HRV down?', 1),
                       ('m2', '11111111-1111-1111-1111-111111111111', 1, 'assistant', 'Late training and less deep sleep.', 2)
                """)
            try db.execute(sql: """
                INSERT INTO memory_facts (id, category, value, identified_at) VALUES ('f1', 'medication', 'Metformin 500mg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO memory_summaries (id, date, summary, topics_json, importance, message_count)
                VALUES ('s1', 1, 'Discussed HRV', '["hrv"]', 'medium', 2)
                """)
            try db.execute(sql: """
                INSERT INTO merkle_leaves (day_id, leaf_version, fields, hash) VALUES (20300, 1, '{"steps":8000}', '0xabc')
                """)
            try db.execute(sql: """
                INSERT INTO merkle_roots (root, start_day, end_day, leaf_count, created_at) VALUES ('0xroot', 20300, 20300, 1, 1)
                """)
            try db.execute(sql: """
                INSERT INTO storj_imports (object_key, data_type, uploaded_at, size, status, payload_json, imported_at)
                VALUES ('merkle-v2/1-a.enc', 'merkle-v2', 1, 10, 'archived', '{"leaves":[]}', 2)
                """)
        }
        try vault.saveLabPdf(Data("%PDF-1.7 Quest Diagnostics lipid panel".utf8), reportId: "bloodwork-1", filename: "panel.pdf")
        return vault
    }

    private func dump(_ vault: VaultDatabase) throws -> [String: [[DatabaseValue]]] {
        let order: [String: String] = [
            "daily_metrics": "day, metric", "lab_reports": "id", "lab_markers": "id", "timeline_events": "id",
            "journal_entries": "id", "chat_sessions": "id", "chat_messages": "id", "memory_facts": "id",
            "memory_summaries": "id", "merkle_leaves": "day_id, leaf_version", "merkle_roots": "root",
            "lab_pdfs": "sha256", "storj_imports": "object_key",
        ]
        return try vault.dbQueue.read { db in
            var out: [String: [[DatabaseValue]]] = [:]
            for (table, orderBy) in order {
                out[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(orderBy)").map { Array($0.databaseValues) }
            }
            return out
        }
    }

    private func pending(_ vault: VaultDatabase) -> Int { vault.pendingBackupCount() }

    // MARK: - Round trip

    func test_backup_then_restore_on_a_wiped_phone_rebuilds_every_table() async throws {
        let source = try seededVault()
        let transport = InMemoryBackupTransport()
        let result = try await BackupEngine(vault: source, key: key, transport: transport).backup()
        XCTAssertTrue(result.committed)
        XCTAssertEqual(pending(source), 0, "everything is backed up")

        let fresh = try VaultDatabase.inMemory()
        let restored = try await BackupEngine(vault: fresh, key: key, transport: transport).restore()
        XCTAssertEqual(restored.chunksKeptLocal, 0)
        XCTAssertGreaterThan(restored.rowsInserted, 15)

        let before = try dump(source), after = try dump(fresh)
        for table in before.keys.sorted() {
            XCTAssertEqual(after[table], before[table], "\(table) differs after restore")
        }
        let sha = BackupKey.sha256Hex(Data("%PDF-1.7 Quest Diagnostics lipid panel".utf8))
        XCTAssertEqual(try Data(contentsOf: fresh.pdfURL(sha256: sha)), Data("%PDF-1.7 Quest Diagnostics lipid panel".utf8))
        XCTAssertEqual(pending(fresh), 0, "restored rows match the backup, so nothing to re-upload")

        // The restored phone can carry on backing up incrementally.
        let next = try await BackupEngine(vault: fresh, key: key, transport: transport).backup()
        XCTAssertEqual(next.uploadedChunks, 0)
    }

    func test_objects_are_opaque_and_small() async throws {
        let source = try seededVault()
        let transport = InMemoryBackupTransport()
        _ = try await BackupEngine(vault: source, key: key, transport: transport).backup()

        XCTAssertFalse(transport.objects.isEmpty)
        let needles = ["steps", "daily_metrics", "Quest", "Metformin", "HRV", "2026-09", "bloodwork", "PDF", "chat"]
        for (id, data) in transport.objects {
            XCTAssertEqual(id.count, 32)
            XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "id \(id) isn't opaque hex")
            XCTAssertLessThan(data.count, 4 * 1024 * 1024)
            XCTAssertEqual(data.first, 0x01)
            for needle in needles {
                XCTAssertNil(data.range(of: Data(needle.utf8)), "plaintext \(needle) visible in \(id)")
            }
        }
        // The root index lives at the key-derived id.
        XCTAssertNotNil(transport.objects[key.indexObjectId])
    }

    func test_wrong_key_cannot_read_the_backup() async throws {
        let transport = InMemoryBackupTransport()
        _ = try await BackupEngine(vault: try seededVault(), key: key, transport: transport).backup()
        let otherKey = BackupKey(symmetricKey: SymmetricKey(data: Data(repeating: 8, count: 32)))
        do {
            _ = try await BackupEngine(vault: try VaultDatabase.inMemory(), key: otherKey, transport: transport).restore()
            XCTFail("restore with another key should fail")
        } catch BackupError.noBackup {
            // Different key → different index id → no backup found. Good.
        }
    }

    // MARK: - Incremental

    func test_a_changed_record_reuploads_only_its_chunk_and_cleans_up() async throws {
        let vault = try seededVault()
        let transport = InMemoryBackupTransport()
        let engine = BackupEngine(vault: vault, key: key, transport: transport)
        _ = try await engine.backup()
        let objectsBefore = Set(transport.objects.keys)

        try await vault.dbQueue.write { db in
            try db.execute(sql: "UPDATE daily_metrics SET total = 12000 WHERE day = '2026-09-02' AND metric = 'steps'")
        }
        XCTAssertEqual(pending(vault), 1)
        let result = try await engine.backup()
        XCTAssertEqual(result.uploadedChunks, 1)
        XCTAssertEqual(pending(vault), 0)

        // One new chunk part, a new index body, same root id; old ones gone.
        let objectsAfter = Set(transport.objects.keys)
        XCTAssertEqual(objectsAfter.count, objectsBefore.count)
        XCTAssertEqual(objectsAfter.subtracting(objectsBefore).count, 2)

        let fresh = try VaultDatabase.inMemory()
        _ = try await BackupEngine(vault: fresh, key: key, transport: transport).restore()
        let total = try await fresh.dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT total FROM daily_metrics WHERE day = '2026-09-02' AND metric = 'steps'")
        }
        XCTAssertEqual(total, 12000)
    }

    func test_unchanged_data_is_not_reuploaded() async throws {
        let vault = try seededVault()
        let transport = InMemoryBackupTransport()
        let engine = BackupEngine(vault: vault, key: key, transport: transport)
        _ = try await engine.backup()
        let puts = transport.putCount
        // Rewrite a row with identical values: triggers bump, bytes don't change.
        try await vault.dbQueue.write { db in
            try db.execute(sql: "UPDATE memory_facts SET value = value WHERE id = 'f1'")
        }
        let result = try await engine.backup()
        XCTAssertEqual(result.uploadedChunks, 0)
        XCTAssertEqual(result.unchangedChunks, 1)
        XCTAssertEqual(transport.putCount, puts)
        XCTAssertEqual(pending(vault), 0)
    }

    func test_deleted_records_leave_the_backup() async throws {
        let vault = try seededVault()
        let transport = InMemoryBackupTransport()
        let engine = BackupEngine(vault: vault, key: key, transport: transport)
        _ = try await engine.backup()

        try await vault.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chat_sessions WHERE id = '11111111-1111-1111-1111-111111111111'")
            try db.execute(sql: "DELETE FROM timeline_events WHERE id = 'evt-1'")
        }
        let result = try await engine.backup()
        XCTAssertEqual(result.removedChunks, 2)
        XCTAssertEqual(pending(vault), 0)

        let fresh = try VaultDatabase.inMemory()
        _ = try await BackupEngine(vault: fresh, key: key, transport: transport).restore()
        let counts = try await fresh.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_messages") ?? -1,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM timeline_events") ?? -1)
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    // MARK: - Crash safety

    func test_an_interrupted_backup_leaves_the_previous_one_restorable() async throws {
        let vault = try seededVault()
        let transport = InMemoryBackupTransport()
        let engine = BackupEngine(vault: vault, key: key, transport: transport)
        _ = try await engine.backup()

        try await vault.dbQueue.write { db in
            try db.execute(sql: "UPDATE lab_markers SET value = 99 WHERE canonical_name = 'ldl_cholesterol'")
            try db.execute(sql: "INSERT INTO memory_facts (id, category, value, identified_at) VALUES ('f2', 'goal', 'Sub-20 5k', 3)")
        }
        transport.failPutsAfter = transport.putCount + 1
        do {
            _ = try await engine.backup()
            XCTFail("expected the upload to fail")
        } catch {}
        XCTAssertGreaterThan(pending(vault), 0, "nothing marked backed up after a failed run")

        // The old index still restores the old data.
        let fresh = try VaultDatabase.inMemory()
        _ = try await BackupEngine(vault: fresh, key: key, transport: transport).restore()
        let ldl = try await fresh.dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT value FROM lab_markers WHERE canonical_name = 'ldl_cholesterol'")
        }
        XCTAssertEqual(ldl, 131)

        // And the next run finishes the job, removing the stray object.
        transport.failPutsAfter = nil
        _ = try await engine.backup()
        XCTAssertEqual(pending(vault), 0)
        let referenced = try referencedIds(vault)
        XCTAssertEqual(Set(transport.objects.keys), referenced)
    }

    func test_backing_up_an_empty_phone_over_an_existing_backup_is_refused() async throws {
        let transport = InMemoryBackupTransport()
        _ = try await BackupEngine(vault: try seededVault(), key: key, transport: transport).backup()
        let newPhone = try VaultDatabase.inMemory()
        try await newPhone.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO daily_metrics (day, metric, total, count, source, updated_at) VALUES ('2026-10-05', 'steps', 1, 1, 'healthkit', 1)")
        }
        do {
            _ = try await BackupEngine(vault: newPhone, key: key, transport: transport).backup()
            XCTFail("should require a restore first")
        } catch BackupEngine.EngineError.needsRestore {}
    }

    // MARK: - Size

    func test_large_objects_are_split_under_four_megabytes() async throws {
        let vault = try VaultDatabase.inMemory()
        var pdf = Data(count: 7 * 1024 * 1024 + 123)
        for i in stride(from: 0, to: pdf.count, by: 4096) { pdf[i] = UInt8(i % 251) }
        try vault.saveLabPdf(pdf, reportId: nil, filename: "scan.pdf")

        let transport = InMemoryBackupTransport()
        _ = try await BackupEngine(vault: vault, key: key, transport: transport).backup()
        XCTAssertTrue(transport.objects.values.allSatisfy { $0.count < 4 * 1024 * 1024 })
        let mirror = try await vault.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT entry_json FROM backup_objects WHERE chunk_key LIKE 'pdf/%'")
        }
        let entry = try BackupJSON.decoder.decode(BackupChunkEntry.self, from: Data(try XCTUnwrap(mirror).utf8))
        XCTAssertEqual(entry.parts.count, 3)

        let fresh = try VaultDatabase.inMemory()
        _ = try await BackupEngine(vault: fresh, key: key, transport: transport).restore()
        XCTAssertEqual(try Data(contentsOf: fresh.pdfURL(sha256: BackupKey.sha256Hex(pdf))), pdf)
    }

    // MARK: - Merge

    func test_restore_keeps_local_rows_and_queues_the_merge() async throws {
        let transport = InMemoryBackupTransport()
        _ = try await BackupEngine(vault: try seededVault(), key: key, transport: transport).backup()

        // New phone: HealthKit already wrote a different value for one day.
        let phone = try VaultDatabase.inMemory()
        try await phone.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO daily_metrics (day, metric, total, count, source, updated_at) VALUES ('2026-09-01', 'steps', 8123, 14, 'healthkit', 9)")
        }
        let result = try await BackupEngine(vault: phone, key: key, transport: transport).restore()
        XCTAssertEqual(result.chunksKeptLocal, 1)
        let rows = try phone.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT day, total FROM daily_metrics WHERE metric = 'steps' AND day LIKE '2026-09-%' ORDER BY day")
        }
        XCTAssertEqual(rows.map { $0["total"] as Double }, [8123, 10500], "local value kept, missing day restored")
        XCTAssertGreaterThan(pending(phone), 0, "the merged month is queued for the next backup")

        // The next backup uploads only the merged month.
        let next = try await BackupEngine(vault: phone, key: key, transport: transport).backup()
        XCTAssertEqual(next.uploadedChunks, 1)
        XCTAssertEqual(pending(phone), 0)
    }

    func test_verify_downloads_and_checks_everything() async throws {
        let vault = try seededVault()
        let transport = InMemoryBackupTransport()
        let engine = BackupEngine(vault: vault, key: key, transport: transport)
        _ = try await engine.backup()
        let verified = try await engine.verify()
        XCTAssertGreaterThan(verified.chunks, 5)

        // Damage one chunk object: verification must fail.
        let bodyIds = try referencedBodyIds(vault)
        let victim = try XCTUnwrap(transport.objects.keys.first { $0 != key.indexObjectId && !bodyIds.contains($0) })
        var damaged = try XCTUnwrap(transport.objects[victim])
        damaged[damaged.count - 1] ^= 0xFF
        try await transport.put([(victim, damaged)])
        do {
            _ = try await engine.verify()
            XCTFail("damaged backup verified")
        } catch {}
    }

    // MARK: - Helpers

    private func referencedBodyIds(_ vault: VaultDatabase) throws -> Set<String> {
        let json = try XCTUnwrap(try vault.meta(BackupEngine.indexBodyKey))
        return Set(try BackupJSON.decoder.decode([BackupChunkEntry.Part].self, from: Data(json.utf8)).map(\.id))
    }

    private func referencedIds(_ vault: VaultDatabase) throws -> Set<String> {
        let entries = try vault.dbQueue.read { db in try String.fetchAll(db, sql: "SELECT entry_json FROM backup_objects") }
        var ids = Set(try entries.flatMap { try BackupJSON.decoder.decode(BackupChunkEntry.self, from: Data($0.utf8)).parts.map(\.id) })
        ids.formUnion(try referencedBodyIds(vault))
        ids.insert(key.indexObjectId)
        return ids
    }
}
