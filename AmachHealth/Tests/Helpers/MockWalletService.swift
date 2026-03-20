// MockWalletService.swift
// AmachHealthTests
//
// Stub WalletService for unit tests — no Privy SDK, no Keychain access.

import Foundation
@testable import AmachHealth

@MainActor
final class MockWalletService: WalletServiceProtocol {
    var isConnected: Bool
    var address: String?
    var encryptionKey: WalletEncryptionKey?

    init(
        isConnected: Bool = true,
        address: String = "0xtest000000000000000000000000000000001",
        encryptionKey: WalletEncryptionKey? = .testFixture()
    ) {
        self.isConnected = isConnected
        self.address = address
        self.encryptionKey = encryptionKey
    }
}

extension WalletEncryptionKey {
    /// Fixture key for tests — deterministically derived from dev mock values.
    static func testFixture() -> WalletEncryptionKey {
        WalletEncryptionKey(
            walletAddress: "0xtest000000000000000000000000000000001",
            encryptionKey: "0000000000000000000000000000000000000000000000000000000000000001",
            signature: "0x" + String(repeating: "ab", count: 65),
            timestamp: 1_700_000_000_000
        )
    }
}
