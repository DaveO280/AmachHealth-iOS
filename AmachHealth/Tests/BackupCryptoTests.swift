// BackupCryptoTests.swift
// AmachHealthTests
//
// Backup format v1 encryption: known-answer vectors (computed outside
// CryptoKit with Node's crypto; see BACKUP-FORMAT.md),
// AAD binding, tampering, and the outbound secret guard.

import XCTest
import CryptoKit
@testable import AmachHealth

final class BackupCryptoTests: XCTestCase {

    private var walletKey: WalletEncryptionKey {
        WalletEncryptionKey(walletAddress: WalletDecryptorFixtures.walletAddress,
                            encryptionKey: WalletDecryptorFixtures.encryptionKey, signature: "0x", timestamp: 0)
    }

    func test_key_derivation_matches_the_published_vector() throws {
        let key = try BackupKey(walletKey: walletKey)
        let bytes = key.symmetricKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(bytes.lowercaseHex, "27397bb0c08c69f280a606cdaf3e16381d31b5a96c2d6465c235574287de9efd")
        XCTAssertEqual(key.indexObjectId, "421dc8852aa7c1bfb2c9be43666c5467")
    }

    func test_backup_key_differs_from_the_vault_key() throws {
        let backup = try BackupKey(walletKey: walletKey).symmetricKey.withUnsafeBytes { Data($0) }
        let vault = try LocalVaultKey(walletKey: walletKey).rawBytes
        XCTAssertNotEqual(backup, vault)
    }

    func test_opens_the_published_object_vector() throws {
        let key = try BackupKey(walletKey: walletKey)
        let object = Data(testHex: "01000102030405060708090a0b520dcba58edeb0098e7a76c21a12dc48a1e2e4fb62b2fd1f99874b4f5a63582f8a")!
        let plaintext = try key.open(object, objectId: "00112233445566778899aabbccddeeff")
        XCTAssertEqual(String(decoding: plaintext, as: UTF8.self), #"{"hello":"amach"}"#)
    }

    func test_seal_layout_and_round_trip() throws {
        let key = try BackupKey(walletKey: walletKey)
        let id = BackupKey.newObjectId()
        let plaintext = Data("vault rows".utf8)
        let sealed = try key.seal(plaintext, objectId: id)
        XCTAssertEqual(sealed.first, 0x01)
        XCTAssertEqual(sealed.count, 1 + 12 + plaintext.count + 16)
        XCTAssertEqual(try key.open(sealed, objectId: id), plaintext)
        // Fresh nonce each time.
        XCTAssertNotEqual(try key.seal(plaintext, objectId: id), sealed)
    }

    func test_object_is_bound_to_its_id_and_key() throws {
        let key = try BackupKey(walletKey: walletKey)
        let sealed = try key.seal(Data("x".utf8), objectId: "a".padding(toLength: 32, withPad: "a", startingAt: 0))
        XCTAssertThrowsError(try key.open(sealed, objectId: "b".padding(toLength: 32, withPad: "b", startingAt: 0)))

        let other = BackupKey(symmetricKey: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try other.open(sealed, objectId: String(repeating: "a", count: 32)))

        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertThrowsError(try key.open(tampered, objectId: String(repeating: "a", count: 32)))

        var wrongVersion = sealed
        wrongVersion[0] = 0x02
        XCTAssertThrowsError(try key.open(wrongVersion, objectId: String(repeating: "a", count: 32))) { error in
            guard case BackupKey.CryptoError.unsupportedVersion(2) = error else { return XCTFail("\(error)") }
        }
    }

    func test_object_ids_are_opaque_hex() {
        let ids = (0..<50).map { _ in BackupKey.newObjectId() }
        XCTAssertEqual(Set(ids).count, 50)
        for id in ids {
            XCTAssertEqual(id.count, 32)
            XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    // MARK: - Outbound guard

    func test_guard_refuses_bodies_that_contain_the_key_or_signature() throws {
        OutboundSecretGuard.resetForTesting()
        defer { OutboundSecretGuard.resetForTesting() }
        let key = WalletEncryptionKey(walletAddress: "0xabc", encryptionKey: WalletDecryptorFixtures.encryptionKey,
                                      signature: "0x" + String(repeating: "ab", count: 65), timestamp: 0)
        OutboundSecretGuard.register(key)

        XCTAssertNoThrow(try OutboundSecretGuard.check(Data(#"{"message":"hi"}"#.utf8)))
        XCTAssertThrowsError(try OutboundSecretGuard.check(try JSONEncoder().encode(["encryptionKey": key])))
        XCTAssertThrowsError(try OutboundSecretGuard.check(Data(WalletDecryptorFixtures.encryptionKey.uppercased().utf8)))
        XCTAssertThrowsError(try OutboundSecretGuard.check(Data(("x" + String(repeating: "ab", count: 65)).utf8)))
    }
}

final class RecordingSigner: BackupSigner {
    let address = WalletDecryptorFixtures.walletAddress
    private(set) var signed: [String] = []
    func sign(_ message: String) async throws -> String {
        signed.append(message)
        return "0x" + String(repeating: "11", count: 65)
    }
}

extension Data {
    init?(testHex: String) {
        var data = Data(capacity: testHex.count / 2)
        var index = testHex.startIndex
        while index < testHex.endIndex {
            let next = testHex.index(index, offsetBy: 2)
            guard let byte = UInt8(testHex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
