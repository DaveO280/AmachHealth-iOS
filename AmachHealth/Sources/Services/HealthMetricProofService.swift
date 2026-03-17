// HealthMetricProofService.swift
// AmachHealth
//
// Builds shareable HealthMetricProofDocument instances from locally
// available metrics, lab data, and DEXA reports. The backend is
// responsible for anchoring these proofs on-chain via V4 attestations.
//
// To add a new metric, append one ProofableMetric entry to `registry`.
// No other files need editing — the UI and proof generation auto-discover it.

import Foundation

@MainActor
final class HealthMetricProofService: ObservableObject {
    static let shared = HealthMetricProofService()

    private let dashboard = DashboardService.shared
    private let wallet = WalletService.shared
    private let api = AmachAPIClient.shared

    @Published private(set) var lastGeneratedProof: HealthMetricProofDocument?

    private init() {}

    // MARK: - Metric Registry

    /// Single source of truth for all provable metrics. The UI, trend lookup,
    /// and proof generation all derive from this array.
    static let registry: [ProofableMetric] = {
        let allPeriods = TrendPeriod.allCases

        // -- HealthKit time-series metrics --
        var metrics: [ProofableMetric] = [
            ProofableMetric(
                id: "heartRateVariabilitySDNN",
                displayName: "HRV",
                icon: "waveform.path.ecg",
                category: .healthKit,
                proofType: .metricChange,
                supportedPeriods: allPeriods,
                subtitle: "Heart rate variability — recovery & stress",
                unit: "ms",
                trendLookup: { d, p in d.hrvTrend[p] ?? [] }
            ),
            ProofableMetric(
                id: "restingHeartRate",
                displayName: "Resting Heart Rate",
                icon: "heart.fill",
                category: .healthKit,
                proofType: .metricChange,
                supportedPeriods: allPeriods,
                subtitle: "Cardiovascular fitness baseline",
                unit: "bpm",
                trendLookup: { d, p in d.rhrTrend[p] ?? [] }
            ),
            ProofableMetric(
                id: "stepCount",
                displayName: "Steps",
                icon: "figure.walk",
                category: .healthKit,
                proofType: .metricChange,
                supportedPeriods: allPeriods,
                subtitle: "Daily step count trend",
                unit: "steps",
                trendLookup: { d, p in d.stepsTrend[p] ?? [] }
            ),
            ProofableMetric(
                id: "sleepAnalysis",
                displayName: "Sleep Duration",
                icon: "bed.double.fill",
                category: .healthKit,
                proofType: .metricChange,
                supportedPeriods: allPeriods,
                subtitle: "Nightly sleep duration trend",
                unit: "hrs",
                trendLookup: { d, p in d.sleepTrend[p] ?? [] }
            ),
            ProofableMetric(
                id: "activeEnergyBurned",
                displayName: "Active Energy",
                icon: "flame.fill",
                category: .healthKit,
                proofType: .metricChange,
                supportedPeriods: allPeriods,
                subtitle: "Calories burned from activity",
                unit: "kcal",
                trendLookup: { d, p in d.calsTrend[p] ?? [] }
            ),
            ProofableMetric(
                id: "appleExerciseTime",
                displayName: "Exercise Minutes",
                icon: "figure.run",
                category: .healthKit,
                proofType: .metricChange,
                supportedPeriods: allPeriods,
                subtitle: "Daily exercise time trend",
                unit: "min",
                trendLookup: { d, p in d.exerciseTrend[p] ?? [] }
            ),
            ProofableMetric(
                id: "vo2Max",
                displayName: "VO2 Max",
                icon: "lungs.fill",
                category: .healthKit,
                proofType: .metricChange,
                supportedPeriods: allPeriods,
                subtitle: "Cardiorespiratory fitness estimate",
                unit: "mL/kg/min",
                trendLookup: { d, p in d.vo2Trend[p] ?? [] }
            ),
            ProofableMetric(
                id: "respiratoryRate",
                displayName: "Respiratory Rate",
                icon: "wind",
                category: .healthKit,
                proofType: .metricChange,
                supportedPeriods: allPeriods,
                subtitle: "Breaths per minute trend",
                unit: "brpm",
                trendLookup: { d, p in d.rrTrend[p] ?? [] }
            ),
            ProofableMetric(
                id: "heartRate",
                displayName: "Heart Rate",
                icon: "heart.circle",
                category: .healthKit,
                proofType: .metricChange,
                supportedPeriods: allPeriods,
                subtitle: "Average heart rate trend",
                unit: "bpm",
                trendLookup: { d, p in d.heartRateTrend[p] ?? [] }
            ),
        ]

        // -- Lab result metrics (point-in-time) --
        let labMetrics: [(String, String, String, ((LabResultSummary) -> Double?))] = [
            ("ldl", "LDL Cholesterol", "mg/dL", { $0.ldl }),
            ("hdl", "HDL Cholesterol", "mg/dL", { $0.hdl }),
            ("triglycerides", "Triglycerides", "mg/dL", { $0.triglycerides }),
            ("hba1c", "HbA1c", "%", { $0.hba1c }),
            ("glucose", "Glucose", "mg/dL", { $0.glucose }),
            ("tsh", "TSH", "mIU/L", { $0.tsh }),
            ("vitaminD", "Vitamin D", "ng/mL", { $0.vitaminD }),
            ("ferritin", "Ferritin", "ng/mL", { $0.ferritin }),
        ]
        for (id, name, unit, extractor) in labMetrics {
            metrics.append(ProofableMetric(
                id: id,
                displayName: name,
                icon: "drop.fill",
                category: .labResult,
                proofType: .labResult,
                subtitle: "From latest bloodwork panel",
                unit: unit,
                labValueExtractor: extractor
            ))
        }

        // -- DEXA / body composition metrics (point-in-time) --
        let dexaMetrics: [(String, String, String, String, ((DexaResultSummary) -> Double?))] = [
            ("bodyFatPercent", "Body Fat", "figure.arms.open", "%", { $0.bodyFatPercent }),
            ("leanMassKg", "Lean Mass", "figure.strengthtraining.traditional", "kg", { $0.leanMassKg }),
            ("visceralFat", "Visceral Fat", "circle.inset.filled", "rating", { $0.visceralFat }),
            ("boneDensityTScore", "Bone Density", "bone", "T-score", { $0.boneDensityTScore }),
            ("androidGynoidRatio", "A:G Ratio", "arrow.left.arrow.right", "ratio", { $0.androidGynoidRatio }),
        ]
        for (id, name, icon, unit, extractor) in dexaMetrics {
            metrics.append(ProofableMetric(
                id: id,
                displayName: name,
                icon: icon,
                category: .bodyComposition,
                proofType: .bodyComposition,
                subtitle: "From latest DEXA scan",
                unit: unit,
                dexaValueExtractor: extractor
            ))
        }

        return metrics
    }()

    // MARK: - Available Metrics (filtered to those with data)

    /// Returns only metrics that have actual data available right now.
    func availableMetrics(
        labSummary: LabResultSummary?,
        dexaSummary: DexaResultSummary?
    ) -> [ProofableMetric] {
        Self.registry.filter { metric in
            switch metric.category {
            case .healthKit:
                guard let lookup = metric.trendLookup else { return false }
                return !lookup(dashboard, .month).isEmpty
            case .labResult:
                guard let lab = labSummary, let extractor = metric.labValueExtractor else { return false }
                return extractor(lab) != nil
            case .bodyComposition:
                guard let dexa = dexaSummary, let extractor = metric.dexaValueExtractor else { return false }
                return extractor(dexa) != nil
            }
        }
    }

    // MARK: - Unified Proof Generation

    /// Generate a proof for any registered metric. This is the primary entry point.
    func generateProof(
        for metric: ProofableMetric,
        period: TrendPeriod = .month,
        labSummary: LabResultSummary? = nil,
        dexaSummary: DexaResultSummary? = nil
    ) async throws -> HealthMetricProofDocument {
        guard wallet.isConnected, let encryptionKey = wallet.encryptionKey else {
            throw ProofError.walletNotConnected
        }

        let claim: HealthMetricClaim

        switch metric.proofType {
        case .metricChange:
            claim = try buildMetricChangeClaim(metric: metric, period: period)

        case .metricRange:
            claim = try buildMetricRangeClaim(metric: metric, period: period)

        case .exerciseSummary:
            claim = try buildExerciseSummaryClaim(period: period)

        case .dataCompleteness:
            claim = try await buildDataCompletenessClaim(period: period)

        case .labResult:
            guard let lab = labSummary else { throw ProofError.insufficientData }
            claim = try buildLabResultClaim(metric: metric, labSummary: lab)

        case .bodyComposition:
            guard let dexa = dexaSummary else { throw ProofError.insufficientData }
            claim = try buildBodyCompositionClaim(metric: metric, dexaSummary: dexa)
        }

        let proof = try await api.generateHealthMetricProof(
            claim: claim,
            walletAddress: encryptionKey.walletAddress
        )

        lastGeneratedProof = proof
        return proof
    }

    // MARK: - Legacy Public API (backward compatibility)

    func generateMetricChangeProof(
        metricKey: String,
        overDays days: Int = 30
    ) async throws -> HealthMetricProofDocument {
        guard let metric = Self.registry.first(where: { $0.id == metricKey }) else {
            throw ProofError.insufficientData
        }
        let period: TrendPeriod
        switch days {
        case ...7: period = .week
        case ...30: period = .month
        default: period = .threeMonths
        }
        return try await generateProof(for: metric, period: period)
    }

    func generateLabResultProof(from summary: LabResultSummary) async throws -> HealthMetricProofDocument {
        // Generate a whole-panel proof using the first available lab metric
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

        let claim = HealthMetricClaim(
            type: .labResult,
            summary: "Bloodwork from \(summary.date): \(coreSummary)",
            metricKey: "lab_panel",
            period: nil,
            details: ["date": summary.date, "panel": "bloodwork"]
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

        let coreSummary = detailPairs.isEmpty
            ? "Body composition scan on \(summary.date)"
            : detailPairs.joined(separator: ", ")

        let claim = HealthMetricClaim(
            type: .bodyComposition,
            summary: "DEXA from \(summary.date): \(coreSummary)",
            metricKey: "body_composition",
            period: nil,
            details: ["date": summary.date, "panel": "dexa"]
        )

        let proof = try await api.generateHealthMetricProof(
            claim: claim,
            walletAddress: encryptionKey.walletAddress
        )
        lastGeneratedProof = proof
        return proof
    }

    // MARK: - Trend Lookup (registry-driven)

    private func trendData(for metricKey: String, period: TrendPeriod) -> [TrendPoint] {
        guard let metric = Self.registry.first(where: { $0.id == metricKey }),
              let lookup = metric.trendLookup else {
            return []
        }
        return lookup(dashboard, period)
    }

    // MARK: - Claim Builders

    private func buildMetricChangeClaim(
        metric: ProofableMetric,
        period: TrendPeriod
    ) throws -> HealthMetricClaim {
        let days = period.days
        let now = Date()
        guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            throw ProofError.invalidDateRange
        }

        let trend = trendData(for: metric.id, period: period)
        guard !trend.isEmpty else { throw ProofError.insufficientData }

        let sorted = trend.sorted { $0.date < $1.date }
        guard let first = sorted.first, let last = sorted.last else {
            throw ProofError.insufficientData
        }

        let delta = last.value - first.value
        let pctChange: Double? = first.value != 0
            ? ((last.value - first.value) / first.value) * 100
            : nil

        let fmt = NumberFormatter()
        fmt.maximumFractionDigits = 1
        fmt.minimumFractionDigits = 0

        let deltaText: String
        if let rendered = fmt.string(from: NSNumber(value: abs(delta))) {
            deltaText = delta >= 0 ? "+\(rendered)" : "-\(rendered)"
        } else {
            deltaText = String(format: "%.1f", delta)
        }

        let pctText: String
        if let pct = pctChange, let rendered = fmt.string(from: NSNumber(value: abs(pct))) {
            pctText = " (\(delta >= 0 ? "+" : "-")\(rendered)%)"
        } else {
            pctText = ""
        }

        let unitSuffix = metric.unit.map { " \($0)" } ?? ""
        let summary = "\(metric.displayName) changed by \(deltaText)\(unitSuffix)\(pctText) over \(days) days"

        let iso = ISO8601DateFormatter()
        return HealthMetricClaim(
            type: .metricChange,
            summary: summary,
            metricKey: metric.id,
            period: .init(start: iso.string(from: startDate), end: iso.string(from: now)),
            details: [
                "startValue": String(first.value),
                "endValue": String(last.value),
                "delta": String(delta)
            ]
        )
    }

    private func buildMetricRangeClaim(
        metric: ProofableMetric,
        period: TrendPeriod
    ) throws -> HealthMetricClaim {
        let days = period.days
        let now = Date()
        guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            throw ProofError.invalidDateRange
        }

        let trend = trendData(for: metric.id, period: period)
        guard !trend.isEmpty else { throw ProofError.insufficientData }

        let values = trend.map(\.value)
        let minVal = values.min()!
        let maxVal = values.max()!
        let avg = values.reduce(0, +) / Double(values.count)

        let fmt = NumberFormatter()
        fmt.maximumFractionDigits = 1
        fmt.minimumFractionDigits = 0

        let minStr = fmt.string(from: NSNumber(value: minVal)) ?? String(format: "%.1f", minVal)
        let maxStr = fmt.string(from: NSNumber(value: maxVal)) ?? String(format: "%.1f", maxVal)
        let avgStr = fmt.string(from: NSNumber(value: avg)) ?? String(format: "%.1f", avg)

        let unitSuffix = metric.unit.map { " \($0)" } ?? ""
        let summary = "\(metric.displayName) ranged from \(minStr) to \(maxStr)\(unitSuffix) (avg \(avgStr)) over \(days) days"

        let iso = ISO8601DateFormatter()
        return HealthMetricClaim(
            type: .metricRange,
            summary: summary,
            metricKey: metric.id,
            period: .init(start: iso.string(from: startDate), end: iso.string(from: now)),
            details: [
                "min": String(minVal),
                "max": String(maxVal),
                "average": String(avg),
                "count": String(values.count)
            ]
        )
    }

    private func buildExerciseSummaryClaim(
        period: TrendPeriod
    ) throws -> HealthMetricClaim {
        let days = period.days
        let now = Date()
        guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            throw ProofError.invalidDateRange
        }

        let exerciseTrend = dashboard.exerciseTrend[period] ?? []
        let totalMinutes = exerciseTrend.reduce(0) { $0 + $1.value }

        let recentWorkouts = dashboard.recentWorkoutSummaries.filter { $0.date >= startDate }
        let workoutCount = recentWorkouts.count

        // Find top activity types
        var activityCounts: [String: Int] = [:]
        for workout in recentWorkouts {
            activityCounts[workout.activityType, default: 0] += 1
        }
        let topActivities = activityCounts.sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)

        guard workoutCount > 0 || totalMinutes > 0 else {
            throw ProofError.insufficientData
        }

        let fmt = NumberFormatter()
        fmt.maximumFractionDigits = 0

        let minsStr = fmt.string(from: NSNumber(value: totalMinutes)) ?? "\(Int(totalMinutes))"
        let activitiesStr = topActivities.isEmpty ? "" : " (\(topActivities.joined(separator: ", ")))"
        let summary = "\(workoutCount) workouts totaling \(minsStr) minutes over \(days) days\(activitiesStr)"

        let iso = ISO8601DateFormatter()
        return HealthMetricClaim(
            type: .exerciseSummary,
            summary: summary,
            metricKey: "exercise",
            period: .init(start: iso.string(from: startDate), end: iso.string(from: now)),
            details: [
                "totalMinutes": String(Int(totalMinutes)),
                "workoutCount": String(workoutCount),
                "topActivities": topActivities.joined(separator: ",")
            ]
        )
    }

    private func buildDataCompletenessClaim(
        period: TrendPeriod
    ) async throws -> HealthMetricClaim {
        let days = period.days
        let now = Date()
        guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now) else {
            throw ProofError.invalidDateRange
        }

        // Determine which metrics have data by checking the registry
        let metricsPresent = Self.registry
            .filter { $0.category == .healthKit }
            .compactMap { metric -> String? in
                guard let lookup = metric.trendLookup,
                      !lookup(dashboard, period).isEmpty else { return nil }
                return metric.id
            }

        let result = HealthKitService.shared.calculateCompleteness(
            metricsPresent: metricsPresent,
            startDate: startDate,
            endDate: now
        )

        let summary = "Health data completeness: \(result.score)% (\(result.tier.rawValue) tier) with \(metricsPresent.count) metrics over \(result.daysCovered) days"

        let iso = ISO8601DateFormatter()
        return HealthMetricClaim(
            type: .dataCompleteness,
            summary: summary,
            metricKey: "completeness",
            period: .init(start: iso.string(from: startDate), end: iso.string(from: now)),
            details: [
                "score": String(result.score),
                "tier": result.tier.rawValue,
                "coreComplete": String(result.coreComplete),
                "daysCovered": String(result.daysCovered),
                "metricsPresent": String(metricsPresent.count)
            ]
        )
    }

    private func buildLabResultClaim(
        metric: ProofableMetric,
        labSummary: LabResultSummary
    ) throws -> HealthMetricClaim {
        guard let extractor = metric.labValueExtractor,
              let value = extractor(labSummary) else {
            throw ProofError.insufficientData
        }

        let fmt = NumberFormatter()
        fmt.maximumFractionDigits = 1
        fmt.minimumFractionDigits = 0
        let valueStr = fmt.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
        let unitStr = metric.unit ?? ""

        let summary = "\(metric.displayName): \(valueStr) \(unitStr) on \(labSummary.date)"

        return HealthMetricClaim(
            type: .labResult,
            summary: summary,
            metricKey: metric.id,
            period: nil,
            details: [
                "date": labSummary.date,
                "value": String(value),
                "unit": unitStr
            ]
        )
    }

    private func buildBodyCompositionClaim(
        metric: ProofableMetric,
        dexaSummary: DexaResultSummary
    ) throws -> HealthMetricClaim {
        guard let extractor = metric.dexaValueExtractor,
              let value = extractor(dexaSummary) else {
            throw ProofError.insufficientData
        }

        let fmt = NumberFormatter()
        fmt.maximumFractionDigits = 1
        fmt.minimumFractionDigits = 0
        let valueStr = fmt.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
        let unitStr = metric.unit ?? ""

        let summary = "\(metric.displayName): \(valueStr) \(unitStr) on \(dexaSummary.date)"

        return HealthMetricClaim(
            type: .bodyComposition,
            summary: summary,
            metricKey: metric.id,
            period: nil,
            details: [
                "date": dexaSummary.date,
                "value": String(value),
                "unit": unitStr
            ]
        )
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
