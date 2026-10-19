// BackupCrypto.swift
// AmachHealth
//
// Backup format v1 encryption (BACKUP-FORMAT.md):
//   key    = HKDF-SHA256(ikm = wallet key bytes, salt = empty, info = "amach-backup-v1", 32 bytes)
//   object = 0x01 || nonce (12) || AES-256-GCM ciphertext || tag (16)
//   AAD    = "amach-backup-v1/" + object id, so an object can't be swapped for another
//
// The key is derived on the phone each time and never stored or sent.

import Foundation
import CryptoKit

struct BackupKey {
    static let info = "amach-backup-v1"
    static let formatVersion: UInt8 = 1

    let symmetricKey: SymmetricKey

    init(walletKey: WalletEncryptionKey) throws {
        let ikm = try LocalVaultKey.keyMaterial(from: walletKey.encryptionKey)
        self.symmetricKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(),
            info: Data(BackupKey.info.utf8),
            outputByteCount: 32
        )
    }

    init(symmetricKey: SymmetricKey) {
        self.symmetricKey = symmetricKey
    }

    /// The root index's object id. Derived from the key so a new phone can
    /// find it, and indistinguishable from the random ids of other objects.
    var indexObjectId: String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("amach-backup-index-v1".utf8), using: symmetricKey)
        return Data(mac).prefix(16).lowercaseHex
    }

    // MARK: - Objects

    enum CryptoError: LocalizedError {
        case unsupportedVersion(UInt8)
        case truncated
        case authenticationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "Backup object version \(v) isn't supported by this app"
            case .truncated: return "Backup object is too short"
            case .authenticationFailed: return "Backup object failed authentication (wrong key or damaged)"
            }
        }
    }

    static func aad(for objectId: String) -> Data {
        Data("amach-backup-v1/\(objectId)".utf8)
    }

    func seal(_ plaintext: Data, objectId: String) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: AES.GCM.Nonce(), authenticating: Self.aad(for: objectId))
        guard let combined = box.combined else { throw CryptoError.truncated }
        var out = Data([Self.formatVersion])
        out.append(combined)
        return out
    }

    func open(_ object: Data, objectId: String) throws -> Data {
        guard let version = object.first else { throw CryptoError.truncated }
        guard version == Self.formatVersion else { throw CryptoError.unsupportedVersion(version) }
        guard object.count >= 1 + 12 + 16 else { throw CryptoError.truncated }
        do {
            let box = try AES.GCM.SealedBox(combined: object.dropFirst())
            return try AES.GCM.open(box, using: symmetricKey, authenticating: Self.aad(for: objectId))
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    // MARK: - Ids and hashes

    /// 16 random bytes as lowercase hex. Says nothing about the contents.
    static func newObjectId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).lowercaseHex
    }

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).lowercaseHex
    }
}

extension Data {
    var lowercaseHex: String { map { String(format: "%02x", $0) }.joined() }
}
