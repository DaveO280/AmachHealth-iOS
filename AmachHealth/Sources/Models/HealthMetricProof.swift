// HealthMetricProof.swift
// AmachHealth
//
// Cross-platform proof document schema for zero-knowledge style
// health claims. Mirrors the web app TypeScript types.

import Foundation

// MARK: - Core Proof Types

enum HealthMetricProofType: String, Codable {
    case metricChange = "metric_change"
    case metricRange = "metric_range"
    case exerciseSummary = "exercise_summary"
    case dataCompleteness = "data_completeness"
    case labResult = "lab_result"
    case bodyComposition = "body_composition"
}

/// Human-readable claim text plus structured payload for the verifier.
struct HealthMetricClaim: Codable, Equatable {
    let type: HealthMetricProofType
    let summary: String          // e.g. "HRV decreased by 12ms (18%) over 30 days"
    let metricKey: String?       // canonical metric identifier, e.g. "hrv", "ldl", "bodyFatPercent"
    let period: ClaimPeriod?     // time window the claim covers
    let details: [String: String]?

    struct ClaimPeriod: Codable, Equatable {
        let start: String        // ISO date (yyyy-MM-dd or ISO8601)
        let end: String
    }
}

/// Prover information — which wallet, which chain, and how the proof
/// is anchored on-chain.
struct HealthMetricProver: Codable, Equatable {
    let walletAddress: String
    let chainId: Int
    let attestationUid: String?
    let attestationTxHash: String?
    let contractAddress: String?
}

/// Evidence links that a verifier can follow:
/// - hashed content stored on Storj
/// - on-chain attestation (contentHash)
/// - backend proof artifacts
struct HealthMetricEvidence: Codable, Equatable {
    let dataContentHash: String?     // hash of underlying data (e.g. Apple Health export or lab JSON)
    let proofHash: String           // hash of this proof document (contentHash)
    let attestationTxHash: String?  // tx hash from V4 attestation
    let storjUri: String?           // encrypted payload location
    let dataType: String?           // e.g. "apple-health-full-export", "bloodwork-report-fhir"
}

/// Runtime metadata about how and when the proof was created.
struct HealthMetricProofMetadata: Codable, Equatable {
    let createdAt: String           // ISO8601 timestamp
    let platform: String            // "ios" / "web"
    let appVersion: String?
    let generator: String?          // e.g. "metric-change/hrv", "lab-result/lipids"
}

/// Top-level proof document that can be shared as JSON between
/// iOS, web app, and 3rd-party verifiers.
struct HealthMetricProofDocument: Codable, Equatable, Identifiable {
    var id: String { proofId }

    let proofId: String             // UUID string
    let claim: HealthMetricClaim
    let prover: HealthMetricProver
    let evidence: HealthMetricEvidence
    let metadata: HealthMetricProofMetadata
    let signature: String           // wallet signature over the proofHash
}

// MARK: - Verification Result Model

/// Public verification response returned by /api/proofs/verify.
struct HealthMetricProofVerificationResult: Codable, Equatable {
    let isValid: Bool
    let reason: String?
    let proof: HealthMetricProofDocument?
}
