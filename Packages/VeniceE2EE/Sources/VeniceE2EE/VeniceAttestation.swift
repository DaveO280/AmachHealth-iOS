// VeniceAttestation.swift
// VeniceE2EE
//
// Fetches a model's attestation straight from Venice (the endpoint needs no
// API key), so Amach's relay is never in a position to hand the phone a
// substitute model key. Then verifies on the device that the key belongs to
// a genuine, non-debug TDX enclave and that the report is fresh:
//
//   REPORTDATA = signing_address (20) ‖ 0x00 × 12 ‖ client nonce (32)
//   signing_address = keccak256(signing_public_key X‖Y)[12..<32]
//
// That layout holds for both enclave gateways Venice uses today (phala's
// aci/1 and near-ai); checked against live attestations on 2026-10-23.

import CryptoKit
import Foundation

public enum VeniceAttestationError: Error, Equatable {
    case http(Int)
    case malformed(String)
    case notVerifiedByVenice
    case nonceMismatch
    case noSigningKey
    case addressMismatch
    case reportDataMismatch
    case quote(TDXQuoteError)
}

public struct AttestedModelKey: Sendable, Equatable {
    public let model: String
    /// 65-byte uncompressed secp256k1 key the enclave decrypts with.
    public let publicKey: Data
    public let signingAddress: String
    public let teeProvider: String?
    public let mrTD: String
    public let rtmrs: [String]
    public let verifiedAt: Date

    public var publicKeyHex: String { publicKey.hexString }

    public init(model: String, publicKey: Data, signingAddress: String, teeProvider: String?,
                mrTD: String, rtmrs: [String], verifiedAt: Date) {
        self.model = model
        self.publicKey = publicKey
        self.signingAddress = signingAddress
        self.teeProvider = teeProvider
        self.mrTD = mrTD
        self.rtmrs = rtmrs
        self.verifiedAt = verifiedAt
    }
}

public struct VeniceAttestationVerifier: Sendable {
    public var baseURL: URL
    /// When false, the quote's signature chain isn't checked (REPORTDATA
    /// binding, nonce and debug bit still are). Strict is the default.
    public var verifyQuoteChain: Bool

    public init(baseURL: URL = URL(string: "https://api.venice.ai/api/v1")!, verifyQuoteChain: Bool = true) {
        self.baseURL = baseURL
        self.verifyQuoteChain = verifyQuoteChain
    }

    public func attest(model: String, session: URLSession = .shared) async throws -> AttestedModelKey {
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, 32, &nonceBytes) == errSecSuccess else {
            throw VeniceAttestationError.malformed("no randomness")
        }
        let nonce = Data(nonceBytes).hexString
        var components = URLComponents(url: baseURL.appendingPathComponent("tee/attestation"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "model", value: model), URLQueryItem(name: "nonce", value: nonce)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw VeniceAttestationError.http(status) }
        return try verify(responseJSON: data, model: model, nonce: nonce)
    }

    /// Verifies a raw attestation response for `nonce` (hex, 32 bytes).
    public func verify(responseJSON: Data, model: String, nonce: String, now: Date = Date()) throws -> AttestedModelKey {
        guard let json = try JSONSerialization.jsonObject(with: responseJSON) as? [String: Any] else {
            throw VeniceAttestationError.malformed("not a JSON object")
        }
        // Venice's own check: necessary, not sufficient.
        guard json["verified"] as? Bool == true else { throw VeniceAttestationError.notVerifiedByVenice }
        let echoed = (json["nonce"] as? String) ?? (json["request_nonce"] as? String)
        guard echoed?.lowercased() == nonce.lowercased() else { throw VeniceAttestationError.nonceMismatch }

        guard let keyHex = (json["signing_key"] as? String) ?? (json["signing_public_key"] as? String) else {
            throw VeniceAttestationError.noSigningKey
        }
        let publicKey = try VeniceE2EECrypto.normalizePublicKey(keyHex)
        guard let addressHex = json["signing_address"] as? String,
              let claimedAddress = Data(hex: addressHex), claimedAddress.count == 20,
              Keccak256.ethereumAddress(uncompressedPublicKey: publicKey) == claimedAddress else {
            throw VeniceAttestationError.addressMismatch
        }

        guard let quoteString = json["intel_quote"] as? String,
              let quoteBytes = Data(hex: quoteString) ?? Data(base64Encoded: quoteString) else {
            throw VeniceAttestationError.malformed("intel_quote missing")
        }
        let quote: TDXQuote
        do {
            quote = try TDXQuote(quoteBytes)
            if quote.isDebug { throw TDXQuoteError.debugTD }
            if verifyQuoteChain { try quote.verify(at: now) }
        } catch let error as TDXQuoteError {
            throw VeniceAttestationError.quote(error)
        }

        var expected = claimedAddress
        expected.append(Data(repeating: 0, count: 12))
        expected.append(Data(hex: nonce) ?? Data())
        guard quote.reportData == expected else { throw VeniceAttestationError.reportDataMismatch }

        return AttestedModelKey(
            model: model,
            publicKey: publicKey,
            signingAddress: "0x" + claimedAddress.hexString,
            teeProvider: json["tee_provider"] as? String,
            mrTD: quote.mrTD.hexString,
            rtmrs: quote.rtmrs.map(\.hexString),
            verifiedAt: now
        )
    }
}
