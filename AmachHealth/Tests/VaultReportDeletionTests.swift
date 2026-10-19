// VaultReportDeletionTests.swift
// AmachHealthTests
//
// Deleting a report from the vault removes it everywhere: its values, its
// original PDF, Luma's context, and the encrypted backup at the next run.

import XCTest
import GRDB
import CryptoKit
@testable import AmachHealth

final class VaultReportDeletionTests: XCTestCase {

    private func vaultWithTwoReports() throws -> VaultDatabase {
        let vault = try VaultDatabase.inMemory()
        for (id, date, ldl) in [("bw-old", "2025-06-01", 131.0), ("bw-new", "2026-05-21", 98.0)] {
            try vault.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO lab_reports (id, kind, report_date, laboratory, created_at, origin, fingerprint)
                    VALUES (?, 'bloodwork', ?, 'Ulta Lab Tests', 1, 'device', ?)
                    """, arguments: [id, date, id])
                try db.execute(sql: """
                    INSERT INTO lab_markers (report_id, position, name, canonical_name, value, unit)
                    VALUES (?, 0, 'LDL Cholesterol', 'ldl_cholesterol', ?, 'mg/dL'),
                           (?, 1, 'HDL Cholesterol', 'hdl_cholesterol', 58, 'mg/dL')
                    """, arguments: [id, ldl, id])
            }
            try vault.saveLabPdf(Data("%PDF \(id)".utf8), reportId: id, filename: "\(id).pdf")
        }
        return vault
    }

    private func count(_ vault: VaultDatabase, _ sql: String) throws -> Int {
        try vault.dbQueue.read { db in try Int.fetchOne(db, sql: sql) ?? -1 }
    }

    func test_delete_removes_the_report_its_values_and_its_pdf_only() throws {
        let vault = try vaultWithTwoReports()
        let pdf = vault.pdfURL(sha256: BackupKey.sha256Hex(Data("%PDF bw-old".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertTrue(vault.hasOriginalPdf(reportId: "bw-old"))

        XCTAssertTrue(try vault.deleteLabReport(id: "bw-old"))

        XCTAssertNil(try vault.labReport(id: "bw-old"))
        XCTAssertEqual(try count(vault, "SELECT COUNT(*) FROM lab_markers WHERE report_id = 'bw-old'"), 0)
        XCTAssertEqual(try count(vault, "SELECT COUNT(*) FROM lab_pdfs WHERE report_id = 'bw-old'"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
        XCTAssertFalse(vault.hasOriginalPdf(reportId: "bw-old"))

        // The other report is untouched.
        XCTAssertEqual(try vault.labReport(id: "bw-new")?.markers.count, 2)
        XCTAssertTrue(vault.hasOriginalPdf(reportId: "bw-new"))

        XCTAssertFalse(try vault.deleteLabReport(id: "bw-old"), "already gone")
    }

    func test_the_next_backup_drops_a_deleted_report() async throws {
        let vault = try vaultWithTwoReports()
        let key = BackupKey(symmetricKey: SymmetricKey(data: Data(repeating: 3, count: 32)))
        let transport = InMemoryBackupTransport()
        let engine = BackupEngine(vault: vault, key: key, transport: transport)
        _ = try await engine.backup()

        try vault.deleteLabReport(id: "bw-old")
        XCTAssertGreaterThan(vault.pendingBackupCount(), 0, "deletions are queued for backup")
        let result = try await engine.backup()
        XCTAssertEqual(result.removedChunks, 2, "the report chunk and its PDF chunk")
        XCTAssertEqual(vault.pendingBackupCount(), 0)

        let restored = try VaultDatabase.inMemory()
        _ = try await BackupEngine(vault: restored, key: key, transport: transport).restore()
        XCTAssertNil(try restored.labReport(id: "bw-old"), "a restore must not bring it back")
        XCTAssertNotNil(try restored.labReport(id: "bw-new"))
    }

    @MainActor
    func test_luma_stops_seeing_a_deleted_report() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-delete-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        BackupService.autoRunEnabled = false
        StorjImportService.autoRunEnabled = false
        defer { BackupService.autoRunEnabled = true; StorjImportService.autoRunEnabled = true }
        let walletKey = WalletEncryptionKey(walletAddress: WalletDecryptorFixtures.walletAddress,
                                            encryptionKey: WalletDecryptorFixtures.encryptionKey, signature: "0x", timestamp: 0)
        LocalVault.shared.open(walletKey: walletKey, directory: dir)
        defer { LocalVault.shared.close(forget: true) }
        let vault = try XCTUnwrap(LocalVault.shared.database)
        try vault.saveLabReport(LabVaultMapping.bloodwork(MockPDFReports.mockBloodworkReport(), id: "bw-1",
                                                           origin: "device", pdfSHA256: nil))
        LabContextService.shared.invalidate()
        XCTAssertTrue(HealthContextBuilder.labBlocks().contains { $0.type == "labs_bloodwork" })

        try VaultReportActions.delete(reportId: "bw-1")
        XCTAssertFalse(HealthContextBuilder.labBlocks().contains { $0.type == "labs_bloodwork" })
    }
}
