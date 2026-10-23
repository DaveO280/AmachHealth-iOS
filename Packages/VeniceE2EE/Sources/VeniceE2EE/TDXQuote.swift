// TDXQuote.swift
// VeniceE2EE
//
// Parses and verifies an Intel TDX DCAP quote (version 4, ECDSA-P256) on the
// device, so the phone doesn't have to take Venice's `verified: true` on
// trust. What's checked here:
//   1. The quote's ECDSA signature over header ‖ TD report, by the quote's
//      attestation key.
//   2. The Quoting Enclave report binds that attestation key:
//      QE REPORTDATA[0..<32] == SHA-256(attestation key ‖ QE auth data).
//   3. The QE report is signed by the PCK leaf certificate's key.
//   4. The PCK chain (leaf → Platform/Processor CA → root) ends at Intel's
//      SGX Root CA, pinned below.
//   5. The TD isn't a debug TD (TDATTRIBUTES bit 0).
// Not checked on the device (see VENICE-E2EE.md): PCK CRLs and TCB level
// (Intel PCS collateral), QE identity, and the workload's measurements
// against a reference (MRTD / RTMRs are exposed for pinning or logging).

import CryptoKit
import Foundation
import Security

public enum TDXQuoteError: Error, Equatable {
    case truncated(String)
    case unsupported(String)
    case badQuoteSignature
    case qeReportNotBound
    case badQEReportSignature
    case certificateChain(String)
    case debugTD
}

public struct TDXQuote: Sendable {
    public let version: Int
    public let teeType: UInt32
    public let tdAttributes: Data
    public let mrTD: Data
    public let rtmrs: [Data]
    public let reportData: Data

    let signedRegion: Data
    let quoteSignature: Data
    let attestationKey: Data
    let qeReport: Data
    let qeReportSignature: Data
    let qeAuthData: Data
    let pckChainDER: [Data]

    static let headerSize = 48
    static let tdReportSize = 584
    static let tdxTEEType: UInt32 = 0x81

    public var isDebug: Bool { (tdAttributes.first ?? 0) & 0x01 != 0 }

    public init(_ quote: Data) throws {
        let q = Data(quote) // zero-based indices
        let bodyEnd = Self.headerSize + Self.tdReportSize
        guard q.count > bodyEnd + 4 else { throw TDXQuoteError.truncated("header/body") }
        version = q.uintLE(at: 0, size: 2)
        let keyType = q.uintLE(at: 2, size: 2)
        teeType = UInt32(q.uintLE(at: 4, size: 4))
        guard version == 4 else { throw TDXQuoteError.unsupported("quote version \(version)") }
        guard keyType == 2 else { throw TDXQuoteError.unsupported("attestation key type \(keyType)") }
        guard teeType == Self.tdxTEEType else { throw TDXQuoteError.unsupported("TEE type \(teeType)") }

        let body = Self.headerSize
        tdAttributes = q.slice(body + 120, 8)!
        mrTD = q.slice(body + 136, 48)!
        rtmrs = (0..<4).map { q.slice(body + 328 + 48 * $0, 48)! }
        reportData = q.slice(body + 520, 64)!
        signedRegion = q.slice(0, bodyEnd)!

        let sigLen = q.uintLE(at: bodyEnd, size: 4)
        guard let sig = q.slice(bodyEnd + 4, sigLen), sig.count >= 134 else {
            throw TDXQuoteError.truncated("signature data")
        }
        quoteSignature = sig.slice(0, 64)!
        attestationKey = sig.slice(64, 64)!
        let certType = sig.uintLE(at: 128, size: 2)
        let certSize = sig.uintLE(at: 130, size: 4)
        guard certType == 6 else { throw TDXQuoteError.unsupported("certification data type \(certType)") }
        guard let qeData = sig.slice(134, certSize), qeData.count >= 450 else {
            throw TDXQuoteError.truncated("QE certification data")
        }
        qeReport = qeData.slice(0, 384)!
        qeReportSignature = qeData.slice(384, 64)!
        let authLen = qeData.uintLE(at: 448, size: 2)
        guard let auth = qeData.slice(450, authLen) else { throw TDXQuoteError.truncated("QE auth data") }
        qeAuthData = auth
        let inner = 450 + authLen
        guard qeData.count >= inner + 6 else { throw TDXQuoteError.truncated("PCK cert header") }
        let innerType = qeData.uintLE(at: inner, size: 2)
        let innerSize = qeData.uintLE(at: inner + 2, size: 4)
        guard innerType == 5 else { throw TDXQuoteError.unsupported("PCK certification data type \(innerType)") }
        guard let pem = qeData.slice(inner + 6, innerSize) else { throw TDXQuoteError.truncated("PCK chain") }
        pckChainDER = Self.derCertificates(fromPEM: String(decoding: pem, as: UTF8.self))
    }

    static func derCertificates(fromPEM pem: String) -> [Data] {
        pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().compactMap { block in
            guard let body = block.components(separatedBy: "-----END CERTIFICATE-----").first else { return nil }
            return Data(base64Encoded: body.filter { !$0.isWhitespace })
        }
    }

    /// Runs checks 1-5 above. Throws on the first failure.
    public func verify(at date: Date = Date()) throws {
        if isDebug { throw TDXQuoteError.debugTD }

        // 1. Quote signature by the attestation key.
        guard let attKey = try? P256.Signing.PublicKey(rawRepresentation: attestationKey),
              let quoteSig = try? P256.Signing.ECDSASignature(rawRepresentation: quoteSignature),
              attKey.isValidSignature(quoteSig, for: signedRegion) else {
            throw TDXQuoteError.badQuoteSignature
        }

        // 2. QE report commits to the attestation key.
        let expected = Data(SHA256.hash(data: attestationKey + qeAuthData))
        guard qeReport.slice(320, 32) == expected else { throw TDXQuoteError.qeReportNotBound }

        // 4 (first, to get a trusted leaf). PCK chain to the pinned root.
        let leafKey = try Self.verifyPCKChain(pckChainDER, at: date)

        // 3. QE report signed by the PCK leaf.
        guard let qeSig = try? P256.Signing.ECDSASignature(rawRepresentation: qeReportSignature),
              leafKey.isValidSignature(qeSig, for: qeReport) else {
            throw TDXQuoteError.badQEReportSignature
        }
    }

    /// Evaluates the chain against Intel's SGX Root CA only; returns the leaf's P-256 key.
    static func verifyPCKChain(_ chain: [Data], at date: Date) throws -> P256.Signing.PublicKey {
        guard chain.count >= 2 else { throw TDXQuoteError.certificateChain("expected leaf + CA(s), got \(chain.count)") }
        let certs = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard certs.count == chain.count,
              let root = SecCertificateCreateWithData(nil, IntelSGXRootCA.der as CFData) else {
            throw TDXQuoteError.certificateChain("unparseable certificate")
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else {
            throw TDXQuoteError.certificateChain("SecTrust create failed")
        }
        SecTrustSetAnchorCertificates(trust, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetVerifyDate(trust, date as CFDate)
        SecTrustSetNetworkFetchAllowed(trust, false)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            throw TDXQuoteError.certificateChain(error.map { CFErrorCopyDescription($0) as String } ?? "untrusted")
        }
        guard let secKey = SecCertificateCopyKey(certs[0]),
              let external = SecKeyCopyExternalRepresentation(secKey, nil) as Data?,
              let key = try? P256.Signing.PublicKey(x963Representation: external) else {
            throw TDXQuoteError.certificateChain("PCK leaf key is not P-256")
        }
        return key
    }
}

/// Intel SGX Root CA (DER), from
/// https://certificates.trustedservices.intel.com/Intel_SGX_Provisioning_Certification_RootCA.cer
/// SHA-256 44a0196b2b99f889b8e149e95b807a350e7424964399e885a7cbb8ccfab674d3, valid to 2049-12-31.
enum IntelSGXRootCA {
    static let sha256 = "44a0196b2b99f889b8e149e95b807a350e7424964399e885a7cbb8ccfab674d3"
    static let der = Data(base64Encoded: """
        MIICjzCCAjSgAwIBAgIUImUM1lqdNInzg7SVUr9QGzknBqwwCgYIKoZIzj0EAwIwaDEaMBgGA1UE
        AwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUludGVsIENvcnBvcmF0aW9uMRQwEgYDVQQH
        DAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJBgNVBAYTAlVTMB4XDTE4MDUyMTEwNDUxMFoX
        DTQ5MTIzMTIzNTk1OVowaDEaMBgGA1UEAwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUlu
        dGVsIENvcnBvcmF0aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJBgNV
        BAYTAlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEC6nEwMDIYZOj/iPWsCzaEKi71OiOSLRF
        hWGjbnBVJfVnkY4u3IjkDYYL0MxO4mqsyYjlBalTVYxFP2sJBK5zlKOBuzCBuDAfBgNVHSMEGDAW
        gBQiZQzWWp00ifODtJVSv1AbOScGrDBSBgNVHR8ESzBJMEegRaBDhkFodHRwczovL2NlcnRpZmlj
        YXRlcy50cnVzdGVkc2VydmljZXMuaW50ZWwuY29tL0ludGVsU0dYUm9vdENBLmRlcjAdBgNVHQ4E
        FgQUImUM1lqdNInzg7SVUr9QGzknBqwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8C
        AQEwCgYIKoZIzj0EAwIDSQAwRgIhAOW/5QkR+S9CiSDcNoowLuPRLsWGf/Yi7GSX94BgwTwgAiEA
        4J0lrHoMs+Xo5o/sX6O9QWxHRAvZUGOdRQ7cvqRXaqI=
        """, options: .ignoreUnknownCharacters)!
}
