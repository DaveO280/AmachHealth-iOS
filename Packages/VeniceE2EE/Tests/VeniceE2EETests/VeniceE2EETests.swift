import Foundation
import P256K
import XCTest
@testable import VeniceE2EE

final class VeniceE2EETests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func json(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    }

    // MARK: Crypto

    func testKeccakEmptyString() {
        XCTAssertEqual(Keccak256.hash(Data()).hexString,
                       "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }

    func testKeccakMultiBlock() {
        // 200 bytes spans two 136-byte blocks; value from @noble/hashes keccak_256.
        XCTAssertEqual(Keccak256.hash(Data(repeating: 0x61, count: 200)).hexString,
                       "96ea54061def936c4be90b518992fdc6f12f535068a256229aca54267b4d084d")
    }

    func testDecryptsNodeReferenceCiphertext() throws {
        // Produced with @noble (the stack Venice's JS sample uses): see node-vector.json.
        let v = try json("node-vector")
        let priv = try P256K.KeyAgreement.PrivateKey(dataRepresentation: Data(hex: v["privateKey"] as! String)!, format: .uncompressed)
        XCTAssertEqual(priv.publicKey.uncompressedRepresentation.hexString, v["publicKey"] as? String)
        XCTAssertEqual(try VeniceE2EECrypto.decrypt(v["ciphertext"] as! String, with: priv), v["plaintext"] as? String)
    }

    func testRoundTripAndFormat() throws {
        let recipient = try VeniceClientKey()
        let modelKey = try VeniceE2EECrypto.normalizePublicKey(recipient.publicKeyHex)
        let hex = try VeniceE2EECrypto.encrypt("HbA1c 5.4%", toModelKey: modelKey)
        XCTAssertTrue(VeniceE2EECrypto.looksEncrypted(hex))
        XCTAssertEqual(hex, hex.lowercased())
        XCTAssertTrue(hex.hasPrefix("04"))
        XCTAssertEqual(hex.count, (65 + 12 + "HbA1c 5.4%".utf8.count + 16) * 2)
        XCTAssertEqual(try recipient.decrypt(hex), "HbA1c 5.4%")
        // Two encryptions of the same text differ (fresh ephemeral + nonce).
        XCTAssertNotEqual(hex, try VeniceE2EECrypto.encrypt("HbA1c 5.4%", toModelKey: modelKey))
    }

    func testTamperedCiphertextFails() throws {
        let recipient = try VeniceClientKey()
        let modelKey = try VeniceE2EECrypto.normalizePublicKey(recipient.publicKeyHex)
        var hex = Array(try VeniceE2EECrypto.encrypt("LDL 130", toModelKey: modelKey))
        hex[hex.count - 1] = hex[hex.count - 1] == "0" ? "1" : "0"
        XCTAssertThrowsError(try recipient.decrypt(String(hex)))
    }

    func testNormalizesBareKey() throws {
        let k = try VeniceClientKey().publicKeyHex
        XCTAssertEqual(try VeniceE2EECrypto.normalizePublicKey(String(k.dropFirst(2))).hexString, k)
        XCTAssertThrowsError(try VeniceE2EECrypto.normalizePublicKey("04" + String(repeating: "0", count: 128)))
    }

    // MARK: Attestation (live responses captured 2026-10-23)

    private func verify(_ name: String, mutate: (inout [String: Any]) -> Void = { _ in }, chain: Bool = true) throws -> AttestedModelKey {
        var j = try json(name)
        let nonce = (j["nonce"] as? String) ?? (j["request_nonce"] as? String) ?? ""
        mutate(&j)
        let data = try JSONSerialization.data(withJSONObject: j)
        // Fixed date inside the PCK certificates' validity.
        let date = ISO8601DateFormatter().date(from: "2026-10-23T17:00:00Z")!
        return try VeniceAttestationVerifier(verifyQuoteChain: chain)
            .verify(responseJSON: data, model: j["model"] as? String ?? "?", nonce: nonce, now: date)
    }

    func testVerifiesPhalaAttestation() throws {
        let key = try verify("attestation-phala-glm-5-3-p")
        XCTAssertEqual(key.signingAddress, "0x79a5061efe5a46b0d1f33b11cf1c5adbedae6b79")
        XCTAssertEqual(key.teeProvider, "phala")
        XCTAssertEqual(key.publicKeyHex.prefix(8), "04943cea")
    }

    func testVerifiesNearAIAttestation() throws {
        let key = try verify("attestation-nearai-deepseek-v4-flash")
        XCTAssertEqual(key.signingAddress, "0x3b753b4406613c5e70ae640508632b600424fa0c")
    }

    func testRejectsSubstitutedKey() throws {
        // A relay or API layer swapping in its own key: address no longer matches.
        let attacker = try VeniceClientKey().publicKeyHex
        XCTAssertThrowsError(try verify("attestation-phala-glm-5-3-p") { $0["signing_public_key"] = attacker }) {
            XCTAssertEqual($0 as? VeniceAttestationError, .addressMismatch)
        }
    }

    func testRejectsStaleNonce() throws {
        XCTAssertThrowsError(try verify("attestation-phala-glm-5-3-p") { $0["nonce"] = String(repeating: "ab", count: 32) }) {
            XCTAssertEqual($0 as? VeniceAttestationError, .nonceMismatch)
        }
    }

    func testRejectsTamperedQuote() throws {
        XCTAssertThrowsError(try verify("attestation-phala-glm-5-3-p") { j in
            var q = Array(j["intel_quote"] as! String)
            // Flip a nibble inside MRTD (TD report offset 48+136).
            let i = (48 + 140) * 2
            q[i] = q[i] == "0" ? "1" : "0"
            j["intel_quote"] = String(q)
        }) {
            XCTAssertEqual($0 as? VeniceAttestationError, .quote(.badQuoteSignature))
        }
    }

    func testRejectsUnverifiedByVenice() throws {
        XCTAssertThrowsError(try verify("attestation-phala-glm-5-3-p") { $0["verified"] = false }) {
            XCTAssertEqual($0 as? VeniceAttestationError, .notVerifiedByVenice)
        }
    }

    func testQuoteFields() throws {
        let j = try json("attestation-phala-glm-5-3-p")
        let quote = try TDXQuote(Data(hex: j["intel_quote"] as! String)!)
        XCTAssertEqual(quote.version, 4)
        XCTAssertFalse(quote.isDebug)
        XCTAssertEqual(quote.pckChainDER.count, 3)
        XCTAssertEqual(quote.reportData.suffix(32).hexString, j["nonce"] as? String)
    }
}
