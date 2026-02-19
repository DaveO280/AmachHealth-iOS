// WalletService.swift
// AmachHealth
//
// Privy wallet integration for iOS
// Handles authentication, signing, and encryption key derivation

import Foundation
import Combine

// Note: This requires the Privy iOS SDK
// Add to Package.swift: .package(url: "https://github.com/privy-io/privy-ios", from: "1.0.0")

// MARK: - Wallet Service

@MainActor
final class WalletService: ObservableObject {
    static let shared = WalletService()

    @Published var isConnected = false
    @Published var address: String?
    @Published var encryptionKey: WalletEncryptionKey?
    @Published var isLoading = false
    @Published var error: String?

    // Privy App ID from environment
    private let privyAppId: String

    // Key derivation message (must match web app)
    private let keyDerivationMessage = """
    Sign this message to derive your encryption key.

    This key is used to encrypt your health data before storage.

    It will NOT be sent to our servers.
    Timestamp: %d
    """

    private init() {
        self.privyAppId = ProcessInfo.processInfo.environment["PRIVY_APP_ID"]
            ?? "YOUR_PRIVY_APP_ID"  // Replace with actual app ID
    }

    // MARK: - Authentication

    /// Connect wallet using Privy
    func connect() async throws {
        isLoading = true
        error = nil
        defer { isLoading = false }

        // TODO: Implement actual Privy SDK integration
        // For now, this is a placeholder that shows the expected flow

        /*
        do {
            // Initialize Privy
            let privy = Privy.shared
            privy.configure(appId: privyAppId)

            // Authenticate (email, social, or existing wallet)
            let user = try await privy.login()

            // Get or create embedded wallet
            let wallet = try await privy.getEmbeddedWallet() ?? privy.createEmbeddedWallet()

            self.address = wallet.address
            self.isConnected = true

            // Derive encryption key
            try await deriveEncryptionKey()

        } catch {
            self.error = error.localizedDescription
            throw WalletError.connectionFailed(error)
        }
        */

        // DEV MOCK: Use a hardcoded development address until Privy iOS SDK ships.
        // Replace this block with the commented Privy SDK flow above when ready.
        let devAddress = "0xDev0000000000000000000000000000AmachDev1"
        let devKey = String(repeating: "a", count: 64) // 64-char hex placeholder
        let devSignature = "0xmock_signature_for_dev"
        let ts = Int(Date().timeIntervalSince1970 * 1000)

        let key = WalletEncryptionKey(
            walletAddress: devAddress,
            encryptionKey: devKey,
            signature: devSignature,
            timestamp: ts
        )
        saveEncryptionKeyToKeychain(key)

        self.encryptionKey = key
        self.address = devAddress
        self.isConnected = true
    }

    /// Disconnect wallet
    func disconnect() async {
        isConnected = false
        address = nil
        encryptionKey = nil

        // TODO: Privy logout
        // await Privy.shared.logout()
    }

    // MARK: - Signing

    /// Sign a message with the wallet
    func signMessage(_ message: String) async throws -> String {
        guard isConnected, address != nil else {
            throw WalletError.notConnected
        }

        // TODO: Implement actual Privy signing
        /*
        let privy = Privy.shared
        let wallet = try await privy.getEmbeddedWallet()
        return try await wallet.signMessage(message)
        */

        throw WalletError.notImplemented
    }

    /// Derive encryption key from wallet signature
    func deriveEncryptionKey() async throws {
        guard let address = address else {
            throw WalletError.notConnected
        }

        isLoading = true
        defer { isLoading = false }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let message = String(format: keyDerivationMessage, timestamp)

        let signature = try await signMessage(message)

        // Derive key from signature (first 32 bytes of keccak256)
        let keyData = signature.data(using: .utf8)!
        let hash = keyData.sha256()
        let keyHex = hash.prefix(32).map { String(format: "%02x", $0) }.joined()

        self.encryptionKey = WalletEncryptionKey(
            walletAddress: address,
            encryptionKey: keyHex,
            signature: signature,
            timestamp: timestamp
        )
    }

    // MARK: - Keychain Storage

    /// Save encryption key to Keychain
    func saveEncryptionKeyToKeychain() throws {
        guard let key = encryptionKey else {
            throw WalletError.noEncryptionKey
        }

        let encoder = JSONEncoder()
        let data = try encoder.encode(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "encryption_key_\(key.walletAddress)",
            kSecAttrService as String: "com.amach.health",
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Delete existing item if present
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw WalletError.keychainError(status)
        }
    }

    /// Load encryption key from Keychain
    func loadEncryptionKeyFromKeychain(for address: String) throws -> WalletEncryptionKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "encryption_key_\(address)",
            kSecAttrService as String: "com.amach.health",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            throw WalletError.keychainError(status)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(WalletEncryptionKey.self, from: data)
    }

    /// Delete encryption key from Keychain
    func deleteEncryptionKeyFromKeychain(for address: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "encryption_key_\(address)",
            kSecAttrService as String: "com.amach.health"
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum WalletError: LocalizedError {
    case notConnected
    case notImplemented
    case noEncryptionKey
    case connectionFailed(Error)
    case signingFailed(Error)
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Wallet is not connected"
        case .notImplemented:
            return "Privy SDK integration not yet implemented"
        case .noEncryptionKey:
            return "No encryption key available"
        case .connectionFailed(let error):
            return "Failed to connect wallet: \(error.localizedDescription)"
        case .signingFailed(let error):
            return "Failed to sign message: \(error.localizedDescription)"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}

// MARK: - Data Extensions

extension Data {
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }
}

// Note: Add to bridging header or use CryptoKit instead
// #import <CommonCrypto/CommonDigest.h>
