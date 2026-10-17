// VaultServicesTests.swift
// AmachHealthTests
//
// End to end inside the app process, with no network: open LocalVault,
// import website-encrypted fixtures, and check that the services the
// screens use (labs, timeline, chat, memory, dashboard) read from the vault.

import XCTest
@testable import AmachHealth

@MainActor
final class VaultServicesTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-services-\(UUID().uuidString)")
        StorjImportService.autoRunEnabled = false
    }

    override func tearDown() async throws {
        LocalVault.shared.close(forget: true)
        StorjImportService.autoRunEnabled = true
        try? FileManager.default.removeItem(at: dir)
    }

    func test_services_read_imported_data_from_the_vault() async throws {
        let key = WalletEncryptionKey(walletAddress: WalletDecryptorFixtures.walletAddress,
                                      encryptionKey: WalletDecryptorFixtures.encryptionKey, signature: "0x", timestamp: 0)
        LocalVault.shared.open(walletKey: key, directory: dir)
        let vault = try XCTUnwrap(LocalVault.shared.database, LocalVault.shared.openError ?? "vault didn't open")

        let importer = StorjObjectImporter(vault: vault)
        for c in WalletDecryptorFixtures.importCases {
            let object = AmachAPIClient.RawStorjObject(key: c.key, size: 0, dataType: c.dataType, uploadedAt: c.uploadedAt)
            importer.recordStatus(importer.importObject(object, bytes: Data(c.objectText.utf8), passphrase: key.encryptionKey), object: object)
        }
        let today = Date().vaultDay
        try vault.upsertDailyMetrics([
            DailyMetricRow(day: today, metric: "steps", total: 4321, count: 9, source: .importIOS),
            DailyMetricRow(day: today, metric: "hrv_sdnn", avg: 48, count: 2, source: .importIOS),
        ], policy: .fillImportedOnly)

        ChatService.shared.vaultDidChange()
        ConversationMemoryStore.shared.vaultDidChange()
        TimelineService.shared.vaultDidChange()
        LabContextService.shared.invalidate()

        // Labs (Luma context) come from the vault, not report/retrieve.
        await LabContextService.shared.load(wallet: WalletService.shared, force: true)
        let labs = try XCTUnwrap(LabContextService.shared.context)
        XCTAssertEqual(labs.bloodwork?.metrics.first?.name, "LDL Cholesterol")
        XCTAssertEqual(labs.dexa?.bodyFatPercent, 18.4)
        XCTAssertEqual(try vault.labReports().count, 2)

        XCTAssertTrue(TimelineService.shared.events.contains { $0.id == "evt-web-1" })
        XCTAssertTrue(ChatService.shared.recentSessions.contains { $0.messages.first?.content == "How did I sleep?" })
        XCTAssertTrue(ConversationMemoryStore.shared.facts.contains { $0.value == "Run a half marathon" })

        await DashboardService.shared.load(force: true)
        XCTAssertEqual(DashboardService.shared.today.hrv, 48)
        XCTAssertGreaterThanOrEqual(DashboardService.shared.today.steps, 4321,
                                    "HealthKit may add today's samples on top; imports never overwrite them")
    }
}
