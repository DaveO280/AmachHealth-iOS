// LocalVaultKey.swift
// AmachHealth
//
// Keys and names the local vault derives from the wallet encryption key.
// Nothing here is stored; everything is re-derived from the Keychain-cached
// WalletEncryptionKey and never leaves the phone.

import Foundation
import CryptoKit

struct LocalVaultKey {
    /// HKDF info string for the vault key. Changing it orphans every vault.
    static let info = "amach-local-db-v1"

    /// 32-byte key: HKDF-SHA256(ikm = wallet key bytes, salt = empty, info).
    let symmetricKey: SymmetricKey
    let walletAddress: String

    init(walletKey: WalletEncryptionKey) throws {
        self.walletAddress = walletKey.walletAddress.lowercased()
        let ikm = try LocalVaultKey.keyMaterial(from: walletKey.encryptionKey)
        self.symmetricKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(),
            info: Data(LocalVaultKey.info.utf8),
            outputByteCount: 32
        )
    }

    /// The wallet key is the 64-char hex PBKDF2 output; HKDF runs over its bytes.
    static func keyMaterial(from hexKey: String) throws -> Data {
        let hex = Array((hexKey.hasPrefix("0x") ? String(hexKey.dropFirst(2)) : hexKey).utf8)
        guard !hex.isEmpty, hex.count % 2 == 0 else { throw KeyError.invalidHex }
        var bytes = Data(capacity: hex.count / 2)
        for i in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(decoding: hex[i..<i + 2], as: UTF8.self), radix: 16) else {
                throw KeyError.invalidHex
            }
            bytes.append(byte)
        }
        return bytes
    }

    enum KeyError: Error { case invalidHex }

    var rawBytes: Data { symmetricKey.withUnsafeBytes { Data($0) } }

    /// Stable, non-reversible id for this wallet's vault file. Ties the file
    /// to the key so a different wallet can never open another wallet's vault.
    var fileIdentifier: String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("vault-file-id".utf8), using: symmetricKey)
        return Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Written into vault_meta on creation and checked on every open.
    var keyCheck: String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("vault-key-check".utf8), using: symmetricKey)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }
}

/// Mirrors generateBucketName in Amach-Website/src/utils/storjAccessControl.ts:
///   `${prefix}-${sha256(lower(address) + "-" + key[0..<32]).hex[0..<16]}`
enum StorjBucketName {
    /// The server's STORJ_BUCKET_PREFIX. Production uses the default.
    static let defaultPrefix = "amach-health"

    static func make(walletAddress: String, encryptionKey: String, prefix: String = defaultPrefix) -> String {
        let material = "\(walletAddress.lowercased())-\(String(encryptionKey.prefix(32)))"
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(hex.prefix(16))"
    }

    static func make(for key: WalletEncryptionKey, prefix: String = defaultPrefix) -> String {
        make(walletAddress: key.walletAddress, encryptionKey: key.encryptionKey, prefix: prefix)
    }
}
