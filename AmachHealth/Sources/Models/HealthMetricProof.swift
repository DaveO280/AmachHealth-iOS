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

struct ProofComparisonOptions: Codable, Equatable {
    let granularity: ComparisonGranularity
    let baselineStartISO: String?
    let baselineEndISO: String?
    let comparisonStartISO: String?
    let comparisonEndISO: String?

    static let `default` = ProofComparisonOptions(
        granularity: .week,
        baselineStartISO: nil,
        baselineEndISO: nil,
        comparisonStartISO: nil,
        comparisonEndISO: nil
    )

    var hasExplicitWindows: Bool {
        baselineStartISO != nil &&
        baselineEndISO != nil &&
        comparisonStartISO != nil &&
        comparisonEndISO != nil
    }
}

enum ComparisonGranularity: String, Codable, CaseIterable {
    case day
    case week
    case month

    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }
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

// MARK: - Proofable Metric Registry Types

/// Category grouping for the proof builder UI.
enum ProofableMetricCategory: String, CaseIterable {
    case healthKit = "Apple Health"
    case labResult = "Lab Results"
    case bodyComposition = "Body Composition"
}

/// Descriptor that drives the proof builder UI, trend lookup, and proof generation.
/// Add one entry to `HealthMetricProofService.registry` to surface a new metric everywhere.
struct ProofableMetric: Identifiable {
    let id: String
    let displayName: String
    let icon: String
    let category: ProofableMetricCategory
    let proofType: HealthMetricProofType
    let supportedPeriods: [TrendPeriod]
    let subtitle: String
    let unit: String?

    /// Fetches trend data from DashboardService for the given period.
    /// Nil for point-in-time metrics (labs, DEXA).
    let trendLookup: ((DashboardService, TrendPeriod) -> [TrendPoint])?

    /// Extracts a single value from a LabResultSummary. Nil for non-lab metrics.
    let labValueExtractor: ((LabResultSummary) -> Double?)?

    /// Extracts a single value from a DexaResultSummary. Nil for non-DEXA metrics.
    let dexaValueExtractor: ((DexaResultSummary) -> Double?)?

    init(
        id: String,
        displayName: String,
        icon: String,
        category: ProofableMetricCategory,
        proofType: HealthMetricProofType,
        supportedPeriods: [TrendPeriod] = [],
        subtitle: String,
        unit: String? = nil,
        trendLookup: ((DashboardService, TrendPeriod) -> [TrendPoint])? = nil,
        labValueExtractor: ((LabResultSummary) -> Double?)? = nil,
        dexaValueExtractor: ((DexaResultSummary) -> Double?)? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.category = category
        self.proofType = proofType
        self.supportedPeriods = supportedPeriods
        self.subtitle = subtitle
        self.unit = unit
        self.trendLookup = trendLookup
        self.labValueExtractor = labValueExtractor
        self.dexaValueExtractor = dexaValueExtractor
    }
}
