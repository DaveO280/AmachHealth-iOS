// LiveStorjImportTests.swift
// AmachHealthTests
//
// Opt-in end-to-end import of a real wallet's Storj bucket through a
// deployed website (storage/list-raw + storage/download-raw), decrypting on
// the simulator. Skipped unless these are set (xcodebuild passes
// TEST_RUNNER_-prefixed variables through to the test process):
//
//   TEST_RUNNER_AMACH_API_URL=https://<preview>.vercel.app
//   TEST_RUNNER_AMACH_LIVE_WALLET=0x...
//   TEST_RUNNER_AMACH_LIVE_KEY=<64-hex wallet encryption key>
//
// The key stays in the test process; only the bucket name is sent.

import XCTest
@testable import AmachHealth

@MainActor
final class LiveStorjImportTests: XCTestCase {

    func test_live_import_completes_with_no_failures() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AMACH_API_URL"] != nil,
              let wallet = env["AMACH_LIVE_WALLET"], let hexKey = env["AMACH_LIVE_KEY"] else {
            throw XCTSkip("Set AMACH_API_URL, AMACH_LIVE_WALLET and AMACH_LIVE_KEY to run")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        StorjImportService.autoRunEnabled = false
        defer { StorjImportService.autoRunEnabled = true }
        let key = WalletEncryptionKey(walletAddress: wallet.lowercased(), encryptionKey: hexKey, signature: "0x", timestamp: 0)
        LocalVault.shared.open(walletKey: key, directory: dir)
        defer { LocalVault.shared.close(forget: true) }
        let vault = try XCTUnwrap(LocalVault.shared.database)

        StorjImportService.shared.run(vault: vault, walletKey: key)
        let deadline = Date().addingTimeInterval(300)
        while StorjImportService.shared.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        switch StorjImportService.shared.state {
        case .finished(let report):
            let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
            print("LIVE_IMPORT_REPORT \(json)")
            XCTAssertGreaterThan(report.objectsListed, 0)
            XCTAssertEqual(report.failures, [], "failures: \(report.failures)")
            XCTAssertNotNil(try vault.meta(StorjImportService.completedKey))
        case .failed(let message):
            XCTFail("import failed: \(message)")
        default:
            XCTFail("import didn't finish: \(StorjImportService.shared.state)")
        }
    }
}
