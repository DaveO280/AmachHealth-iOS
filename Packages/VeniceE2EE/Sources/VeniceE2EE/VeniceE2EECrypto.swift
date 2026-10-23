// VeniceE2EECrypto.swift
// VeniceE2EE
//
// Venice's E2EE message format (docs.venice.ai/guides/features/tee-e2ee-models):
//   hex( ephemeralPub65 ‖ nonce12 ‖ AES-256-GCM(ciphertext ‖ tag16) )
//   key = HKDF-SHA256(ikm: ECDH x-coordinate, salt: none, info: "ecdsa_encryption", 32 bytes)
// on secp256k1. Requests are encrypted to the model's attested key with a
// fresh ephemeral per message; Venice encrypts each reply chunk to the
// client key sent in X-Venice-TEE-Client-Pub-Key.

import CryptoKit
import Foundation
import P256K

public enum VeniceE2EECryptoError: Error, Equatable {
    case invalidPublicKey
    case malformedCiphertext
    case decryptionFailed
    case notUTF8
}

public enum VeniceE2EECrypto {
    static let hkdfInfo = Data("ecdsa_encryption".utf8)
    /// ephemeral pub (65) + nonce (12) + GCM tag (16).
    static let minimumCiphertextBytes = 93

    /// Accepts 130-hex (04‖X‖Y) or 128-hex (X‖Y) keys, as Venice's samples do.
    public static func normalizePublicKey(_ hex: String) throws -> Data {
        let lower = hex.lowercased()
        let full = (lower.count == 128 && !lower.hasPrefix("04")) ? "04" + lower : lower
        guard full.count == 130, full.hasPrefix("04"), let data = Data(hex: full) else {
            throw VeniceE2EECryptoError.invalidPublicKey
        }
        _ = try publicKey(data) // on-curve check
        return data
    }

    static func publicKey(_ uncompressed: Data) throws -> P256K.KeyAgreement.PublicKey {
        do {
            return try P256K.KeyAgreement.PublicKey(dataRepresentation: uncompressed, format: .uncompressed)
        } catch {
            throw VeniceE2EECryptoError.invalidPublicKey
        }
    }

    static func aesKey(privateKey: P256K.KeyAgreement.PrivateKey,
                       peer: P256K.KeyAgreement.PublicKey) -> SymmetricKey {
        // Compressed point = prefix ‖ X; Venice uses the raw 32-byte X.
        let shared = privateKey.sharedSecretFromKeyAgreement(with: peer, format: .compressed)
        let x = shared.withUnsafeBytes { Data($0).dropFirst() }
        return HKDF<CryptoKit.SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: x),
                                      info: hkdfInfo,
                                      outputByteCount: 32)
    }

    /// Encrypts one message's content to a model's enclave key.
    public static func encrypt(_ plaintext: String, toModelKey modelKey: Data) throws -> String {
        let peer = try publicKey(modelKey)
        let ephemeral = try P256K.KeyAgreement.PrivateKey(format: .uncompressed)
        let key = aesKey(privateKey: ephemeral, peer: peer)
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: AES.GCM.Nonce())
        var out = ephemeral.publicKey.uncompressedRepresentation
        out.append(contentsOf: sealed.nonce)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out.hexString
    }

    /// True for strings shaped like an encrypted chunk (Venice's own heuristic).
    public static func looksEncrypted(_ s: String) -> Bool {
        s.count >= minimumCiphertextBytes * 2 && s.allSatisfy(\.isHexDigit)
    }

    /// Decrypts a reply chunk encrypted to `clientKey`.
    public static func decrypt(_ hex: String, with clientKey: P256K.KeyAgreement.PrivateKey) throws -> String {
        guard let raw = Data(hex: hex), raw.count >= minimumCiphertextBytes,
              let serverPub = raw.slice(0, 65), let nonceBytes = raw.slice(65, 12),
              let body = raw.slice(77, raw.count - 77) else {
            throw VeniceE2EECryptoError.malformedCiphertext
        }
        let peer = try publicKey(serverPub)
        let key = aesKey(privateKey: clientKey, peer: peer)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceBytes),
                                            ciphertext: body.dropLast(16),
                                            tag: body.suffix(16))
            let plain = try AES.GCM.open(box, using: key)
            guard let text = String(data: plain, encoding: .utf8) else { throw VeniceE2EECryptoError.notUTF8 }
            return text
        } catch let error as VeniceE2EECryptoError {
            throw error
        } catch {
            throw VeniceE2EECryptoError.decryptionFailed
        }
    }
}

/// A per-request client key pair. Venice encrypts the reply to its public half.
public struct VeniceClientKey: Sendable {
    let privateKey: P256K.KeyAgreement.PrivateKey

    public init() throws {
        privateKey = try P256K.KeyAgreement.PrivateKey(format: .uncompressed)
    }

    /// 130 lowercase hex chars (04‖X‖Y) for X-Venice-TEE-Client-Pub-Key.
    public var publicKeyHex: String { privateKey.publicKey.uncompressedRepresentation.hexString }

    public func decrypt(_ hex: String) throws -> String {
        try VeniceE2EECrypto.decrypt(hex, with: privateKey)
    }
}
