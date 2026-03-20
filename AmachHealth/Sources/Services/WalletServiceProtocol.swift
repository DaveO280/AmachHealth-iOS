// WalletServiceProtocol.swift
// AmachHealth
//
// Protocol abstracting WalletService for dependency injection in tests.
// WalletService conforms retroactively below.

import Foundation

/// The minimal surface ChatService reads from WalletService.
protocol WalletServiceProtocol: AnyObject {
    var isConnected: Bool { get }
    var address: String? { get }
    var encryptionKey: WalletEncryptionKey? { get }
}

// MARK: - WalletService retroactive conformance
extension WalletService: WalletServiceProtocol {}
