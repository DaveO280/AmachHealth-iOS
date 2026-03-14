// HealthMetricProofService.swift
// AmachHealth
//
// Builds shareable HealthMetricProofDocument instances from locally
// available metrics, lab data, and DEXA reports. The backend is
// responsible for anchoring these proofs on-chain via V4 attestations.

import Foundation

@MainActor
final class HealthMetricProofService: ObservableObject {
    static let shared = HealthMetricProofService()

    private let dashboard = DashboardService.shared
    private let wallet = WalletService.shared
    private let api = AmachAPIClient.shared

    @Published private(set) var lastGeneratedProof: HealthMetricProofDocument?

    private init() {}

    // MARK: - Public API

    func generateMetricChangeProof(
        metricKey: String,
        overDays days: Int = 30
    ) async throws -> HealthMetricProofDocument {
        guard wallet.isConnected, let encryptionKey = wallet.encryptionKey else {
            throw ProofError.walletNotConnected
        }

        let now = Date()
        guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            throw ProofError.invalidDateRange
        }

        // Use the correct DashboardService trend for the requested metric.
        let trend = trendData(for: metricKey, period: .month)
        guard !trend.isEmpty else {
            throw ProofError.insufficientData
        }

        let sorted = trend.sorted { $0.date < $1.date }
        guard let first = sorted.first, let last = sorted.last else {
            throw ProofError.insufficientData
        }

        let delta = last.value - first.value
        let pctChange: Double?
        if first.value != 0 {
            pctChange = ((last.value - first.value) / first.value) * 100
        } else {
            pctChange = nil
        }

        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0

        let deltaText: String
        if let rendered = formatter.string(from: NSNumber(value: abs(delta))) {
            deltaText = delta >= 0 ? "+\(rendered)" : "-\(rendered)"
        } else {
            deltaText = String(format: "%.1f", delta)
        }

        let pctText: String
        if let pct = pctChange, let rendered = formatter.string(from: NSNumber(value: abs(pct))) {
            pctText = " (\(delta >= 0 ? "+" : "-")\(rendered)%)"
        } else {
            pctText = ""
        }

        let metricName = metricKey.timelineMetricName
        let summary = "\(metricName) changed by \(deltaText)\(pctText) over \(days) days"

        let dateFormatter = ISO8601DateFormatter()
        let claim = HealthMetricClaim(
            type: .metricChange,
            summary: summary,
            metricKey: metricKey,
            period: .init(
                start: dateFormatter.string(from: startDate),
                end: dateFormatter.string(from: now)
            ),
            details: [
                "startValue": String(first.value),
                "endValue": String(last.value),
                "delta": String(delta)
            ]
        )

        // Ask backend to generate proofHash + signature and anchor on-chain.
        let proof = try await api.generateHealthMetricProof(
            claim: claim,
            walletAddress: encryptionKey.walletAddress
        )

        lastGeneratedProof = proof
        return proof
    }

    func generateLabResultProof(from summary: LabResultSummary) async throws -> HealthMetricProofDocument {
        guard wallet.isConnected, let encryptionKey = wallet.encryptionKey else {
            throw ProofError.walletNotConnected
        }

        let metricPieces: [String] = [
            summary.ldl.map { "LDL \($0) mg/dL" },
            summary.hdl.map { "HDL \($0) mg/dL" },
            summary.triglycerides.map { "Triglycerides \($0) mg/dL" },
            summary.hba1c.map { "HbA1c \($0)%" }
        ].compactMap { $0 }

        let coreSummary: String
        if metricPieces.isEmpty {
            coreSummary = "Lab panel on \(summary.date) within recorded ranges"
        } else {
            coreSummary = metricPieces.joined(separator: ", ")
        }

        let summaryText = "Bloodwork from \(summary.date): \(coreSummary)"

        let claim = HealthMetricClaim(
            type: .labResult,
            summary: summaryText,
            metricKey: "lab_panel",
            period: nil,
            details: [
                "date": summary.date,
                "panel": "bloodwork"
            ]
        )

        let proof = try await api.generateHealthMetricProof(
            claim: claim,
            walletAddress: encryptionKey.walletAddress
        )

        lastGeneratedProof = proof
        return proof
    }

    func generateBodyCompositionProof(from summary: DexaResultSummary) async throws -> HealthMetricProofDocument {
        guard wallet.isConnected, let encryptionKey = wallet.encryptionKey else {
            throw ProofError.walletNotConnected
        }

        var detailPairs: [String] = []
        if let bodyFat = summary.bodyFatPercent {
            detailPairs.append(String(format: "Body fat %.1f%%", bodyFat))
        }
        if let leanMass = summary.leanMassKg {
            detailPairs.append(String(format: "Lean mass %.1f kg", leanMass))
        }
        if let visceral = summary.visceralFat {
            detailPairs.append(String(format: "Visceral fat %.1f", visceral))
        }
        if let tScore = summary.boneDensityTScore {
            detailPairs.append(String(format: "Bone density T-score %.1f", tScore))
        }

        let coreSummary: String
        if detailPairs.isEmpty {
            coreSummary = "Body composition scan on \(summary.date)"
        } else {
            coreSummary = detailPairs.joined(separator: ", ")
        }

        let summaryText = "DEXA from \(summary.date): \(coreSummary)"

        let claim = HealthMetricClaim(
            type: .bodyComposition,
            summary: summaryText,
            metricKey: "body_composition",
            period: nil,
            details: [
                "date": summary.date,
                "panel": "dexa"
            ]
        )

        let proof = try await api.generateHealthMetricProof(
            claim: claim,
            walletAddress: encryptionKey.walletAddress
        )

        lastGeneratedProof = proof
        return proof
    }
    // MARK: - Trend Lookup

    /// Returns the correct trend array from DashboardService for a given metric key.
    private func trendData(for metricKey: String, period: TrendPeriod) -> [TrendPoint] {
        switch metricKey {
        case "heartRateVariabilitySDNN":
            return dashboard.hrvTrend[period] ?? []
        case "restingHeartRate":
            return dashboard.rhrTrend[period] ?? []
        case "stepCount":
            return dashboard.stepsTrend[period] ?? []
        case "sleepAnalysis":
            return dashboard.sleepTrend[period] ?? []
        case "activeEnergyBurned":
            return dashboard.calsTrend[period] ?? []
        case "appleExerciseTime":
            return dashboard.exerciseTrend[period] ?? []
        case "vo2Max":
            return dashboard.vo2Trend[period] ?? []
        case "respiratoryRate":
            return dashboard.rrTrend[period] ?? []
        case "heartRate":
            return dashboard.heartRateTrend[period] ?? []
        default:
            // Fall back to HRV for unknown keys.
            return dashboard.hrvTrend[period] ?? []
        }
    }
}

// MARK: - Errors

enum ProofError: LocalizedError {
    case walletNotConnected
    case invalidDateRange
    case insufficientData

    var errorDescription: String? {
        switch self {
        case .walletNotConnected:
            return "Please connect your wallet to generate proofs"
        case .invalidDateRange:
            return "Invalid date range for proof generation"
        case .insufficientData:
            return "Not enough data to generate this proof"
        }
    }
}
