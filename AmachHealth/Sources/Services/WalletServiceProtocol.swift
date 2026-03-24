// WalletServiceProtocol.swift
// AmachHealth
//
// Protocol abstracting WalletService for dependency injection in tests.
// WalletService conforms retroactively below.

import Foundation

/// The minimal surface ChatService and ZKSyncAttestationService read from WalletService.
protocol WalletServiceProtocol: AnyObject {
    var isConnected: Bool { get }
    var address: String? { get }
    var encryptionKey: WalletEncryptionKey? { get }
    func sendTransaction(to: String, data: String, chainId: Int) async throws -> String
}

// MARK: - WalletService retroactive conformance
extension WalletService: WalletServiceProtocol {}
