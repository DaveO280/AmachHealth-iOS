// HealthMetricProofTests.swift
// AmachHealthTests
//
// Lightweight tests for HealthMetricProofDocument models. These tests
// avoid networking and focus on encoding/decoding stability.

import XCTest
@testable import AmachHealth

final class HealthMetricProofModelTests: XCTestCase {

    func test_roundTripEncoding_decoding_proofDocument() throws {
        let claim = HealthMetricClaim(
            type: .metricChange,
            summary: "HRV changed by -12ms over 30 days",
            metricKey: "heartRateVariabilitySDNN",
            period: .init(start: "2025-01-01T00:00:00Z", end: "2025-01-31T00:00:00Z"),
            details: ["startValue": "80", "endValue": "68"]
        )

        let prover = HealthMetricProver(
            walletAddress: "0x1234",
            chainId: 280,
            attestationUid: "0xattest",
            attestationTxHash: "0xtx",
            contractAddress: "0xcontract"
        )

        let evidence = HealthMetricEvidence(
            dataContentHash: "sha256:data",
            proofHash: "sha256:proof",
            attestationTxHash: "0xtx",
            storjUri: "storj://bucket/proof.json",
            dataType: "apple-health-full-export"
        )

        let metadata = HealthMetricProofMetadata(
            createdAt: "2025-02-01T12:00:00Z",
            platform: "ios",
            appVersion: "1.0.0",
            generator: "metric-change/hrv"
        )

        let proof = HealthMetricProofDocument(
            proofId: UUID().uuidString.lowercased(),
            claim: claim,
            prover: prover,
            evidence: evidence,
            metadata: metadata,
            signature: "0xsig"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(proof)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(HealthMetricProofDocument.self, from: data)

        XCTAssertEqual(decoded.claim.summary, proof.claim.summary)
        XCTAssertEqual(decoded.prover.walletAddress, proof.prover.walletAddress)
        XCTAssertEqual(decoded.evidence.proofHash, proof.evidence.proofHash)
        XCTAssertEqual(decoded.metadata.platform, "ios")
        XCTAssertEqual(decoded.signature, proof.signature)
    }

    func test_verificationResult_decodes_basicShape() throws {
        let json = """
        {
            "isValid": true,
            "reason": null,
            "proof": {
                "proofId": "proof-1",
                "claim": {
                    "type": "data_completeness",
                    "summary": "I have 90 days of Apple Health data at 85% completeness",
                    "metricKey": "appleHealth",
                    "period": {
                        "start": "2025-01-01",
                        "end": "2025-03-31"
                    },
                    "details": {
                        "daysCovered": "90",
                        "score": "85"
                    }
                },
                "prover": {
                    "walletAddress": "0x1234",
                    "chainId": 280,
                    "attestationUid": null,
                    "attestationTxHash": "0xtx",
                    "contractAddress": null
                },
                "evidence": {
                    "dataContentHash": "sha256:data",
                    "proofHash": "sha256:proof",
                    "attestationTxHash": "0xtx",
                    "storjUri": "storj://bucket/proof.json",
                    "dataType": "apple-health-full-export"
                },
                "metadata": {
                    "createdAt": "2025-04-01T12:00:00Z",
                    "platform": "web",
                    "appVersion": "1.0.0",
                    "generator": "data-completeness"
                },
                "signature": "0xsig"
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let result = try decoder.decode(HealthMetricProofVerificationResult.self, from: json)

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.proof?.claim.type, .dataCompleteness)
        XCTAssertEqual(result.proof?.claim.metricKey, "appleHealth")
        XCTAssertEqual(result.proof?.evidence.dataType, "apple-health-full-export")
    }
}
