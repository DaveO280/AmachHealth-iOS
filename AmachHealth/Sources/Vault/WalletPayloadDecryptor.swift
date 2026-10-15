// WalletPayloadDecryptor.swift
// AmachHealth
//
// On-device decryption of Storj objects written by the website's
// encryptWithWalletKey (src/utils/walletEncryption.ts).
//
// Every object the backend stores (StorageService.storeHealthData) is the
// UTF-8 text "0x" + CryptoJS.AES.encrypt(JSON.stringify(data), key). With a
// string key CryptoJS uses passphrase mode, which is OpenSSL's format:
//
//   base64( "Salted__" ‖ salt(8) ‖ AES-256-CBC/PKCS#7 ciphertext )
//   key ‖ iv = EVP_BytesToKey(MD5, passphrase = key string as UTF-8, salt, 1 round)
//
// The passphrase is the 64-char hex key string itself, not its decoded bytes.

import Foundation
import CommonCrypto
import CryptoKit

enum WalletPayloadDecryptor {

    enum DecryptError: LocalizedError, Equatable {
        case notUTF8
        case invalidBase64
        case missingSaltHeader
        case truncated
        case cryptorFailed(Int32)
        case wrongKeyOrCorrupt
        case invalidJSON

        var errorDescription: String? {
            switch self {
            case .notUTF8: return "Object is not UTF-8 text"
            case .invalidBase64: return "Object is not base64 ciphertext"
            case .missingSaltHeader: return "Ciphertext is missing the Salted__ header"
            case .truncated: return "Ciphertext is truncated"
            case .cryptorFailed(let status): return "AES decrypt failed (\(status))"
            case .wrongKeyOrCorrupt: return "Wrong key or corrupted data"
            case .invalidJSON: return "Decrypted payload is not JSON"
            }
        }
    }

    private static let saltHeader = Array("Salted__".utf8)

    /// Decrypt raw Storj object bytes to the plaintext string (normally JSON).
    static func decrypt(objectBytes: Data, passphrase: String) throws -> String {
        guard let text = String(data: objectBytes, encoding: .utf8) else {
            throw DecryptError.notUTF8
        }
        return try decrypt(objectText: text, passphrase: passphrase)
    }

    /// Decrypt "0x"-prefixed (or bare) CryptoJS passphrase ciphertext.
    static func decrypt(objectText: String, passphrase: String) throws -> String {
        var b64 = objectText.trimmingCharacters(in: .whitespacesAndNewlines)
        if b64.hasPrefix("0x") { b64.removeFirst(2) }
        guard let blob = Data(base64Encoded: b64) else { throw DecryptError.invalidBase64 }

        let bytes = [UInt8](blob)
        guard bytes.count >= 16, Array(bytes[0..<8]) == saltHeader else {
            throw DecryptError.missingSaltHeader
        }
        let salt = Array(bytes[8..<16])
        let ciphertext = Array(bytes[16...])
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw DecryptError.truncated
        }

        let (key, iv) = evpBytesToKey(passphrase: Array(passphrase.utf8), salt: salt)
        let plain = try aes256CBCDecrypt(ciphertext, key: key, iv: iv)

        // CryptoJS returns "" when UTF-8 decoding fails, and the website treats
        // an empty result as a wrong key. A bad key usually fails PKCS#7 first.
        guard let string = String(bytes: plain, encoding: .utf8), !string.isEmpty else {
            throw DecryptError.wrongKeyOrCorrupt
        }
        return string
    }

    /// Decrypt and parse the JSON value the backend wrapped (JSON.stringify(data)).
    static func decryptJSON(objectBytes: Data, passphrase: String) throws -> Any {
        let text = try decrypt(objectBytes: objectBytes, passphrase: passphrase)
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { throw DecryptError.invalidJSON }
        return value
    }

    /// Decrypt and decode the wrapped JSON straight into a Decodable type.
    static func decryptDecodable<T: Decodable>(
        _ type: T.Type,
        objectBytes: Data,
        passphrase: String,
        decoder: JSONDecoder = VaultJSON.decoder
    ) throws -> T {
        let text = try decrypt(objectBytes: objectBytes, passphrase: passphrase)
        return try decoder.decode(T.self, from: Data(text.utf8))
    }

    // MARK: - OpenSSL EVP_BytesToKey (MD5, 1 iteration) → 32-byte key + 16-byte IV

    static func evpBytesToKey(passphrase: [UInt8], salt: [UInt8]) -> (key: [UInt8], iv: [UInt8]) {
        var derived: [UInt8] = []
        var previous: [UInt8] = []
        while derived.count < 48 {
            var md5 = Insecure.MD5()
            md5.update(data: previous)
            md5.update(data: passphrase)
            md5.update(data: salt)
            previous = Array(md5.finalize())
            derived += previous
        }
        return (Array(derived[0..<32]), Array(derived[32..<48]))
    }

    private static func aes256CBCDecrypt(_ input: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key, key.count,
            iv,
            input, input.count,
            &output, output.count,
            &moved
        )
        guard status == kCCSuccess else {
            // kCCDecodeError is what a wrong key looks like (bad padding).
            if status == CCCryptorStatus(kCCDecodeError) { throw DecryptError.wrongKeyOrCorrupt }
            throw DecryptError.cryptorFailed(status)
        }
        return Array(output[0..<moved])
    }
}

/// Shared JSON coding for vault payloads. Dates accept ISO-8601 (with or
/// without fractional seconds) and Unix seconds/ms, since iOS and web wrote both.
enum VaultJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = parseISODate(string) { return date }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date \(string)")
            }
            let number = try container.decode(Double.self)
            // Apple reference-date seconds (JSONEncoder default) are < 1e9 for
            // dates before 2032; Unix ms are > 1e11. Unix seconds sit between.
            if number > 100_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
            if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
            return Date(timeIntervalSinceReferenceDate: number)
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func parseISODate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let dayOnly = ISO8601DateFormatter()
        dayOnly.formatOptions = [.withFullDate]
        return dayOnly.date(from: string)
    }
}
