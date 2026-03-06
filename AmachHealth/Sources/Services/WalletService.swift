// WalletService.swift
// AmachHealth
//
// Privy wallet integration for iOS.
// Handles authentication, embedded wallet management, message signing,
// and PBKDF2 encryption key derivation (cross-platform compatible with web app).
//
// Key derivation MUST produce identical output to the web's walletEncryption.ts.
// Parameters: PBKDF2, 100k iterations, SHA-256, salt = wallet address bytes.

import Foundation
import Combine
import CryptoKit
import CommonCrypto

#if canImport(PrivySDK)
import PrivySDK
#endif

// MARK: - Wallet Service

@MainActor
final class WalletService: ObservableObject {
    static let shared = WalletService()

    @Published var isConnected = false
    @Published var address: String?
    @Published var encryptionKey: WalletEncryptionKey?
    @Published var isLoading = false
    @Published var error: String?
    /// Email pending OTP verification (set by sendEmailCode, cleared on success/failure).
    @Published var pendingEmail: String?

    /// True after first successful Privy auth (persisted via UserDefaults).
    @Published var hasAuthenticatedBefore: Bool

    // Privy config — set your App ID and Client ID from the Privy Dashboard.
    // The Client ID is created under App Settings → Clients → "iOS" client type.
    private let privyAppId = "cmiev4g03026zl80cpoyjccwu"        // TODO: Replace
    private let privyClientId = "client-WY6TLxngkdjGfUtmZkKe5evREPGvJ7Z7jeQXBd5BcxJE5"    // TODO: Replace

    #if canImport(PrivySDK)
    private var privy: (any Privy)?
    #endif

    // ──────────────────────────────────────────────────────────
    // MARK: - Key Derivation Constants (MUST match web exactly)
    // ──────────────────────────────────────────────────────────
    // Source of truth: Amach-Website/src/utils/walletEncryption.ts
    //
    // ⚠️  NEVER change these values — doing so makes all existing
    //     encrypted Storj data unrecoverable.

    /// The deterministic message the user signs to derive their encryption key.
    /// Web equivalent: `ENCRYPTION_KEY_MESSAGE + walletAddress.toLowerCase()`
    private static let encryptionKeyMessagePrefix =
        "Amach Health - Derive Encryption Key\n\nThis signature is used to encrypt your health data.\n\nNonce: "

    /// PBKDF2 iteration count — must match `walletEncryption.ts` line 144 & 209.
    private static let pbkdf2Iterations = 100_000

    /// Derived key length in bytes (256 bits = 32 bytes).
    private static let derivedKeyLengthBytes = 32

    // ──────────────────────────────────────────────────────────
    // MARK: - Init
    // ──────────────────────────────────────────────────────────

    private init() {
        self.hasAuthenticatedBefore = UserDefaults.standard.bool(forKey: "amach_has_authenticated")
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Privy Setup
    // ──────────────────────────────────────────────────────────

    /// Call once at app launch (e.g. in AmachHealthApp.task).
    func initializePrivy() {
        #if canImport(PrivySDK)
        let config = PrivyConfig(appId: privyAppId, appClientId: privyClientId)
        self.privy = PrivySdk.initialize(config: config)

        // Check for an existing authenticated session (returning user).
        Task { await restoreSessionIfAvailable() }
        #else
        print("⚠️ PrivySDK not installed — running in dev-mock mode.")
        Task { try? await connectDevMock() }
        #endif
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Authentication
    // ──────────────────────────────────────────────────────────

    // ──────────────────────────────────────────────────────────
    // MARK: - Email OTP Login (matches web app loginMethods: ["email"])
    // ──────────────────────────────────────────────────────────

    /// Step 1 — request OTP. Call from ConnectWalletSheet after user enters email.
    func sendEmailCode(to email: String) async throws {
        error = nil
        #if canImport(PrivySDK)
        guard let privy else { throw WalletError.notConfigured }
        isLoading = true
        defer { isLoading = false }
        do {
            try await privy.email.sendCode(to: email)
            pendingEmail = email
        } catch {
            self.error = error.localizedDescription
            throw error
        }
        #else
        // Dev mock: skip straight to code step
        pendingEmail = email
        #endif
    }

    /// Step 2 — verify OTP, recover/create wallet, derive encryption key.
    /// Call from ConnectWalletSheet after user enters 6-digit code.
    func loginWithEmailCode(_ code: String) async throws {
        error = nil
        #if canImport(PrivySDK)
        guard let privy, let email = pendingEmail else { throw WalletError.notConfigured }
        isLoading = true
        defer { isLoading = false }
        do {
            let user = try await privy.email.loginWithCode(code, sentTo: email)
            try await finishConnecting(user: user)
            pendingEmail = nil
        } catch {
            self.error = error.localizedDescription
            throw WalletError.connectionFailed(error)
        }
        #else
        try await connectDevMock()
        pendingEmail = nil
        #endif
    }

    #if canImport(PrivySDK)
    /// Shared wallet setup called after any successful login.
    private func finishConnecting(user: any PrivyUser) async throws {
        // Get existing embedded wallet or create one
        let wallet: any EmbeddedEthereumWallet
        if let existing = user.embeddedEthereumWallets.first {
            wallet = existing
        } else {
            wallet = try await user.createEthereumWallet()
        }

        self.address = wallet.address.lowercased()
        self.isConnected = true
        self.hasAuthenticatedBefore = true
        UserDefaults.standard.set(true, forKey: "amach_has_authenticated")

        // Try Keychain first (avoids re-signing on every launch)
        if let cached = try? loadEncryptionKeyFromKeychain(for: wallet.address.lowercased()) {
            self.encryptionKey = cached
            return
        }

        // Derive encryption key (requires wallet signature — first connection only)
        try await deriveAndStoreEncryptionKey(wallet: wallet)
    }

    /// Restore a previous Privy session on app launch (silent — no login UI shown).
    private func restoreSessionIfAvailable() async {
        guard let privy = privy else { return }

        let authState = await privy.getAuthState()
        guard case .authenticated(let user) = authState else { return }

        guard let wallet = user.embeddedEthereumWallets.first else { return }
        self.address = wallet.address.lowercased()
        self.isConnected = true

        if let cached = try? loadEncryptionKeyFromKeychain(for: wallet.address.lowercased()) {
            self.encryptionKey = cached
        }
    }
    #endif

    /// Dev-only mock for building/testing without Privy SDK installed.
    private func connectDevMock() async throws {
        isLoading = true
        defer { isLoading = false }

        let devAddress = "0xdev0000000000000000000000000000amachdev1"

        // Derive a real PBKDF2 key using a mock signature so the pipeline is exercised.
        let mockSignature = "0x" + String(repeating: "ab", count: 65)  // 130 hex chars
        let derivedKey = try Self.deriveEncryptionKeyPBKDF2(
            signatureHex: mockSignature,
            walletAddress: devAddress
        )

        let key = WalletEncryptionKey(
            walletAddress: devAddress,
            encryptionKey: derivedKey,
            signature: mockSignature,
            timestamp: Int(Date().timeIntervalSince1970 * 1000)
        )

        self.encryptionKey = key
        try? saveEncryptionKeyToKeychain()
        self.address = devAddress
        self.isConnected = true
    }

    /// Disconnect wallet and clear local state.
    func disconnect() async {
        if let addr = address {
            deleteEncryptionKeyFromKeychain(for: addr)
        }
        isConnected = false
        address = nil
        encryptionKey = nil

        #if canImport(PrivySDK)
        if let privy = privy,
           case .authenticated(let user) = await privy.getAuthState() {
            await user.logout()
        }
        #endif
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Signing
    // ──────────────────────────────────────────────────────────

    /// Sign a message with the embedded wallet.
    func signMessage(_ message: String) async throws -> String {
        guard isConnected, address != nil else {
            throw WalletError.notConnected
        }

        #if canImport(PrivySDK)
        guard let privy = privy else { throw WalletError.notConfigured }

        guard case .authenticated(let user) = await privy.getAuthState(),
              let wallet = user.embeddedEthereumWallets.first else {
            throw WalletError.notConnected
        }

        let request = EthereumRpcRequest(
            method: "personal_sign",
            params: [message, wallet.address]
        )
        let signature = try await wallet.provider.request(request)
        return signature
        #else
        throw WalletError.notImplemented
        #endif
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Encryption Key Derivation
    // ──────────────────────────────────────────────────────────

    #if canImport(PrivySDK)
    /// Sign the deterministic message, derive PBKDF2 key, store in Keychain.
    private func deriveAndStoreEncryptionKey(wallet: any EmbeddedEthereumWallet) async throws {
        isLoading = true
        defer { isLoading = false }

        let walletAddress = wallet.address.lowercased()

        // 1. Build deterministic message (MUST match web walletEncryption.ts)
        let message = Self.encryptionKeyMessagePrefix + walletAddress

        // 2. Request wallet signature
        let request = EthereumRpcRequest(
            method: "personal_sign",
            params: [message, wallet.address]
        )
        let signature = try await wallet.provider.request(request)

        guard signature.count >= 132 else {
            throw WalletError.signingFailed(
                NSError(domain: "WalletService", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Signature too short (\(signature.count) chars)"])
            )
        }

        // 3. Derive key via PBKDF2 (cross-platform compatible)
        let derivedKeyHex = try Self.deriveEncryptionKeyPBKDF2(
            signatureHex: signature,
            walletAddress: walletAddress
        )

        // 4. Store
        let key = WalletEncryptionKey(
            walletAddress: walletAddress,
            encryptionKey: derivedKeyHex,
            signature: signature,
            timestamp: Int(Date().timeIntervalSince1970 * 1000)
        )
        self.encryptionKey = key
        try saveEncryptionKeyToKeychain()
    }
    #endif

    /// Re-derive encryption key (e.g. if Keychain was cleared).
    /// Call from UI when `encryptionKey == nil` but `isConnected == true`.
    func rederiveEncryptionKey() async throws {
        guard isConnected else { throw WalletError.notConnected }

        #if canImport(PrivySDK)
        guard let privy = privy,
              case .authenticated(let user) = await privy.getAuthState(),
              let wallet = user.embeddedEthereumWallets.first else {
            throw WalletError.notConnected
        }
        try await deriveAndStoreEncryptionKey(wallet: wallet)
        #else
        throw WalletError.notImplemented
        #endif
    }

    /// Returns a usable encryption key, re-deriving it if needed.
    /// When `forceRefresh` is true, always prompt for a fresh signature.
    func ensureEncryptionKey(forceRefresh: Bool = false) async throws -> WalletEncryptionKey {
        guard isConnected else { throw WalletError.notConnected }

        if !forceRefresh, let encryptionKey {
            return encryptionKey
        }

        try await rederiveEncryptionKey()

        guard let encryptionKey else {
            throw WalletError.noEncryptionKey
        }

        return encryptionKey
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - PBKDF2 Key Derivation (Cross-Platform Compatible)
    // ──────────────────────────────────────────────────────────
    //
    // This function MUST produce the exact same output as:
    //   Amach-Website/src/utils/walletEncryption.ts → deriveKeyWithWebCrypto()
    //
    // Algorithm:
    //   Input:    signature hex bytes (strip "0x" prefix, decode hex → raw bytes)
    //   Salt:     wallet address hex bytes (strip "0x", first 40 hex chars → 20 bytes)
    //   Hash:     SHA-256
    //   Rounds:   100,000
    //   Output:   256 bits (32 bytes) → lowercase hex string
    //
    // ⚠️  If you change ANY parameter here, iOS will derive different keys
    //     than the web app, and cross-platform Storj data will be unreadable.

    static func deriveEncryptionKeyPBKDF2(
        signatureHex: String,
        walletAddress: String
    ) throws -> String {
        // 1. Parse signature: strip "0x" prefix, decode hex to bytes
        let sigHex = signatureHex.hasPrefix("0x")
            ? String(signatureHex.dropFirst(2))
            : signatureHex
        let signatureBytes = try hexToBytes(sigHex)

        // 2. Parse salt: strip "0x", take first 40 hex chars (20 bytes = Ethereum address)
        var saltHex = walletAddress.lowercased()
        if saltHex.hasPrefix("0x") {
            saltHex = String(saltHex.dropFirst(2))
        }
        saltHex = String(saltHex.prefix(40))
        let saltBytes = try hexToBytes(saltHex)

        // 3. PBKDF2 derivation using CryptoKit (non-blocking on iOS)
        //    CryptoKit doesn't expose PBKDF2 directly, so we use CommonCrypto.
        let derivedKey = try pbkdf2SHA256(
            password: signatureBytes,
            salt: saltBytes,
            iterations: pbkdf2Iterations,
            keyLength: derivedKeyLengthBytes
        )

        // 4. Convert to lowercase hex string (matches web's format)
        return derivedKey.map { String(format: "%02x", $0) }.joined()
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - PBKDF2 via CommonCrypto
    // ──────────────────────────────────────────────────────────

    private static func pbkdf2SHA256(
        password: [UInt8],
        salt: [UInt8],
        iterations: Int,
        keyLength: Int
    ) throws -> [UInt8] {
        var derivedKey = [UInt8](repeating: 0, count: keyLength)

        let status = password.withUnsafeBufferPointer { passwordPtr in
            salt.withUnsafeBufferPointer { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPtr.baseAddress, password.count,
                    saltPtr.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derivedKey, keyLength
                )
            }
        }

        guard status == kCCSuccess else {
            throw WalletError.keyDerivationFailed(status)
        }

        return derivedKey
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Hex Utilities
    // ──────────────────────────────────────────────────────────

    /// Convert a hex string to a byte array.
    /// "a1b2c3" → [0xa1, 0xb2, 0xc3]
    static func hexToBytes(_ hex: String) throws -> [UInt8] {
        guard hex.count % 2 == 0 else {
            throw WalletError.invalidHex
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)

        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
                throw WalletError.invalidHex
            }
            bytes.append(byte)
            index = nextIndex
        }

        return bytes
    }

    // ──────────────────────────────────────────────────────────
    // MARK: - Keychain Storage
    // ──────────────────────────────────────────────────────────

    /// Save encryption key to Keychain.
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

    /// Load encryption key from Keychain.
    func loadEncryptionKeyFromKeychain(for walletAddress: String) throws -> WalletEncryptionKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "encryption_key_\(walletAddress)",
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

    /// Delete encryption key from Keychain.
    func deleteEncryptionKeyFromKeychain(for walletAddress: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "encryption_key_\(walletAddress)",
            kSecAttrService as String: "com.amach.health"
        ]

        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Errors

enum WalletError: LocalizedError {
    case notConnected
    case notConfigured
    case notImplemented
    case noEncryptionKey
    case invalidHex
    case connectionFailed(Error)
    case signingFailed(Error)
    case keyDerivationFailed(Int32)
    case keychainError(OSStatus)
    case useLoginSheet   // caller should present ConnectWalletSheet

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Wallet is not connected"
        case .notConfigured:
            return "Privy SDK not configured. Call initializePrivy() first."
        case .notImplemented:
            return "Privy SDK not installed. Add via Xcode: File → Add Package Dependencies → github.com/privy-io/privy-ios"
        case .useLoginSheet:
            return "Please use the Connect Wallet button to sign in."
        case .noEncryptionKey:
            return "No encryption key available"
        case .invalidHex:
            return "Invalid hex string"
        case .connectionFailed(let error):
            return "Failed to connect wallet: \(error.localizedDescription)"
        case .signingFailed(let error):
            return "Failed to sign message: \(error.localizedDescription)"
        case .keyDerivationFailed(let status):
            return "PBKDF2 key derivation failed (status: \(status))"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}

// MARK: - Data Extension

extension Data {
    func sha256() -> Data {
        Data(SHA256.hash(data: self))
    }
}
