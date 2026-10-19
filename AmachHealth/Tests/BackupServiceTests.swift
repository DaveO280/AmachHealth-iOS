// BackupServiceTests.swift
// AmachHealthTests
//
// BackupService on in-memory vaults and transport: the toggle backs up,
// "last backed up" updates, and a new phone restores automatically.

import XCTest
import GRDB
@testable import AmachHealth

@MainActor
final class BackupServiceTests: XCTestCase {

    private let walletKey = WalletEncryptionKey(
        walletAddress: WalletDecryptorFixtures.walletAddress,
        encryptionKey: WalletDecryptorFixtures.encryptionKey, signature: "0x", timestamp: 0
    )

    override func tearDown() async throws {
        BackupService.shared.vaultDidClose()
    }

    private func vaultWithData() throws -> VaultDatabase {
        let vault = try VaultDatabase.inMemory(walletAddress: walletKey.walletAddress)
        try vault.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO daily_metrics (day, metric, total, count, source, updated_at)
                VALUES ('2026-10-01', 'steps', 7000, 1, 'healthkit', 1)
                """)
            try db.execute(sql: """
                INSERT INTO memory_facts (id, category, value, identified_at) VALUES ('f1', 'goal', 'Sleep 8h', 1)
                """)
        }
        return vault
    }

    func test_turning_backup_on_backs_up_and_records_when() async throws {
        let vault = try vaultWithData()
        let transport = InMemoryBackupTransport()
        let service = BackupService.shared
        service.attachForTesting(vault: vault, walletKey: walletKey, transport: transport)
        XCTAssertFalse(service.isEnabled)

        try vault.setMeta(BackupService.enabledKey, "1")
        service.attachForTesting(vault: vault, walletKey: walletKey, transport: transport)
        let ok = await service.runBackup()

        XCTAssertTrue(ok)
        XCTAssertEqual(service.state, .idle)
        XCTAssertNotNil(service.lastBackedUpAt)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertNotNil(transport.objects[try BackupKey(walletKey: walletKey).indexObjectId])
        XCTAssertTrue(EncryptedBackupSection.statusLine(service).hasPrefix("Last backed up"))
    }

    func test_backup_does_nothing_while_off() async throws {
        let transport = InMemoryBackupTransport()
        BackupService.shared.attachForTesting(vault: try vaultWithData(), walletKey: walletKey, transport: transport)
        let ok = await BackupService.shared.runBackup()
        XCTAssertFalse(ok)
        XCTAssertTrue(transport.objects.isEmpty)
    }

    func test_a_new_phone_restores_and_turns_backup_on() async throws {
        let transport = InMemoryBackupTransport()
        _ = try await BackupEngine(vault: try vaultWithData(), key: try BackupKey(walletKey: walletKey), transport: transport).backup()

        let newPhone = try VaultDatabase.inMemory(walletAddress: walletKey.walletAddress)
        XCTAssertTrue(BackupService.looksNew(newPhone))
        let service = BackupService.shared
        service.attachForTesting(vault: newPhone, walletKey: walletKey, transport: transport)
        await service.restoreIfNewPhone()

        XCTAssertTrue(service.isEnabled)
        XCTAssertNotNil(service.lastRestore)
        let fact = try await newPhone.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM memory_facts WHERE id = 'f1'")
        }
        XCTAssertEqual(fact, "Sleep 8h")
        XCTAssertNotNil(try newPhone.meta(BackupService.restoreCheckedKey))

        // Runs once per vault.
        try await newPhone.dbQueue.write { db in try db.execute(sql: "DELETE FROM memory_facts") }
        await service.restoreIfNewPhone()
        let count = try await newPhone.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_facts") }
        XCTAssertEqual(count, 0)
    }

    func test_no_backup_marks_the_check_done() async throws {
        let newPhone = try VaultDatabase.inMemory(walletAddress: walletKey.walletAddress)
        let service = BackupService.shared
        service.attachForTesting(vault: newPhone, walletKey: walletKey, transport: InMemoryBackupTransport())
        await service.restoreIfNewPhone()
        XCTAssertFalse(service.isEnabled)
        XCTAssertNotNil(try newPhone.meta(BackupService.restoreCheckedKey))
        XCTAssertEqual(service.state, .idle)
    }
}
