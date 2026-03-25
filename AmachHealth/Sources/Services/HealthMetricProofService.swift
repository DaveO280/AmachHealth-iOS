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
    private var cachedStorjDailySummaries: [String: DailySummary]?
    private var cachedStorjWalletAddress: String?
    private var cachedStorjLoadedAt: Date?

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
        comparison: ProofComparisonOptions = .default,
        labSummary: LabResultSummary? = nil,
        dexaSummary: DexaResultSummary? = nil
    ) async throws -> HealthMetricProofDocument {
        guard wallet.isConnected, let encryptionKey = wallet.encryptionKey else {
            throw ProofError.walletNotConnected
        }

        let claim: HealthMetricClaim

        switch metric.proofType {
        case .metricChange:
            claim = try await buildMetricChangeClaim(
                metric: metric,
                period: period,
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey,
                comparison: comparison
            )

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

        var proof = try await api.generateHealthMetricProof(
            claim: claim,
            walletAddress: encryptionKey.walletAddress
        )

        // Anchor on-chain: submit the proofHash as a contentHash attestation
        // via the user's Privy wallet — same pattern as the web app.
        do {
            proof = try await anchorOnChain(proof: proof, claim: claim, period: period)
            print("⛓️ [Proof] On-chain anchoring succeeded — txHash=\(proof.prover.attestationTxHash ?? "nil")")
        } catch {
            print("⛓️ [Proof] On-chain anchoring failed: \(error.localizedDescription) — proof still valid off-chain")
        }

        lastGeneratedProof = proof
        return proof
    }

    /// Submit a createAttestation tx with the proof's contentHash.
    /// Returns an updated proof document with the real txHash.
    private func anchorOnChain(
        proof: HealthMetricProofDocument,
        claim: HealthMetricClaim,
        period: TrendPeriod?
    ) async throws -> HealthMetricProofDocument {
        let dataType: UInt8 = switch claim.type {
        case .bodyComposition: 0   // DEXA
        case .labResult:       1   // Bloodwork
        case .metricChange, .metricRange, .exerciseSummary, .dataCompleteness: 2  // Apple Health
        }

        let now = Date()
        let days = period?.days ?? 30
        let startDate = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now

        let input = ZKSyncAttestationService.AttestationInput(
            contentHash: proof.evidence.proofHash,
            dataType: dataType,
            startDate: startDate,
            endDate: now,
            completenessScore: 100,
            recordCount: 1,
            coreComplete: true
        )

        let result = try await ZKSyncAttestationService.shared.createAttestation(input)

        // Return a new proof document with the real tx hash filled in
        return HealthMetricProofDocument(
            proofId: proof.proofId,
            claim: proof.claim,
            prover: HealthMetricProver(
                walletAddress: proof.prover.walletAddress,
                chainId: proof.prover.chainId,
                attestationUid: nil,
                attestationTxHash: result.txHash,
                contractAddress: proof.prover.contractAddress
            ),
            evidence: HealthMetricEvidence(
                dataContentHash: proof.evidence.dataContentHash,
                proofHash: proof.evidence.proofHash,
                attestationTxHash: result.txHash,
                storjUri: proof.evidence.storjUri,
                dataType: proof.evidence.dataType
            ),
            metadata: proof.metadata,
            signature: proof.signature
        )
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
        period: TrendPeriod,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        comparison: ProofComparisonOptions
    ) async throws -> HealthMetricClaim {
        if metric.category == .healthKit,
           let storjClaim = try? await buildStorjWeeklyAverageClaim(
            metric: metric,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            comparison: comparison
           ) {
            return storjClaim
        }

        return try buildLocalMetricChangeClaim(metric: metric, period: period)
    }

    private func buildLocalMetricChangeClaim(
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
                "aggregationType": "daily_delta",
                "startValue": String(first.value),
                "endValue": String(last.value),
                "delta": String(delta)
            ]
        )
    }

    private func buildStorjWeeklyAverageClaim(
        metric: ProofableMetric,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        comparison: ProofComparisonOptions
    ) async throws -> HealthMetricClaim {
        let summariesByDay = try await loadStorjDailySummaries(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )

        var dailyPoints: [(date: Date, value: Double)] = []
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = Calendar(identifier: .gregorian)
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"

        for (dateKey, summary) in summariesByDay {
            guard let date = dateFormatter.date(from: dateKey),
                  let value = metricValue(for: metric.id, from: summary) else {
                continue
            }
            dailyPoints.append((date: date, value: value))
        }

        guard !dailyPoints.isEmpty else { throw ProofError.insufficientData }

        let weekly = computeWeeklyAverages(from: dailyPoints)
        let selected = selectComparisonWindows(from: weekly, comparison: comparison)
        guard let baseline = selected?.baseline, let latest = selected?.latest else {
            throw ProofError.insufficientData
        }

        let delta = latest.average - baseline.average
        let pctChange = baseline.average != 0 ? ((latest.average - baseline.average) / baseline.average) * 100 : nil

        let fmt = NumberFormatter()
        fmt.maximumFractionDigits = 1
        fmt.minimumFractionDigits = 0

        let baselineStr = fmt.string(from: NSNumber(value: baseline.average)) ?? String(format: "%.1f", baseline.average)
        let latestStr = fmt.string(from: NSNumber(value: latest.average)) ?? String(format: "%.1f", latest.average)
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
        let summary = "\(metric.displayName) weekly average moved from \(baselineStr)\(unitSuffix) to \(latestStr)\(unitSuffix), change \(deltaText)\(unitSuffix)\(pctText)"

        let iso = ISO8601DateFormatter()
        #if DEBUG
        print("""
        🧪 [Proof] built weekly claim metric=\(metric.id)
        🧪 [Proof] baselineWeek=\(iso.string(from: baseline.weekStart)) avg=\(baseline.average) days=\(baseline.dayCount)
        🧪 [Proof] comparisonWeek=\(iso.string(from: latest.weekStart)) avg=\(latest.average) days=\(latest.dayCount)
        🧪 [Proof] delta=\(delta) mode=\("user_selected_windows")
        """)
        #endif
        return HealthMetricClaim(
            type: .metricChange,
            summary: summary,
            metricKey: metric.id,
            period: .init(start: iso.string(from: baseline.weekStart), end: iso.string(from: latest.weekEnd)),
            details: [
                "aggregationType": "weekly_average",
                "comparisonMode": "user_selected_windows",
                "baselineRangeStart": comparison.baselineStartISO ?? iso.string(from: baseline.weekStart),
                "baselineRangeEnd": comparison.baselineEndISO ?? iso.string(from: baseline.weekEnd),
                "comparisonRangeStart": comparison.comparisonStartISO ?? iso.string(from: latest.weekStart),
                "comparisonRangeEnd": comparison.comparisonEndISO ?? iso.string(from: latest.weekEnd),
                "baselineWeekStart": iso.string(from: baseline.weekStart),
                "latestWeekStart": iso.string(from: latest.weekStart),
                "baselineAverage": String(baseline.average),
                "latestAverage": String(latest.average),
                "baselineDayCount": String(baseline.dayCount),
                "latestDayCount": String(latest.dayCount),
                "weeklyPointsUsed": String(weekly.count),
                "delta": String(delta)
            ]
        )
    }

    private func selectComparisonWindows(
        from weekly: [WeeklyAggregate],
        comparison: ProofComparisonOptions
    ) -> (baseline: WeeklyAggregate, latest: WeeklyAggregate)? {
        let iso = ISO8601DateFormatter()
        let hasExplicitRanges =
            comparison.baselineStartISO != nil &&
            comparison.baselineEndISO != nil &&
            comparison.comparisonStartISO != nil &&
            comparison.comparisonEndISO != nil

        if hasExplicitRanges,
           let baselineStart = comparison.baselineStartISO.flatMap({ iso.date(from: $0) }),
           let baselineEnd = comparison.baselineEndISO.flatMap({ iso.date(from: $0) }),
           let comparisonStart = comparison.comparisonStartISO.flatMap({ iso.date(from: $0) }),
           let comparisonEnd = comparison.comparisonEndISO.flatMap({ iso.date(from: $0) }) {
            let baselineWindow = weekly.filter { $0.weekStart >= baselineStart && $0.weekStart <= baselineEnd }
            let comparisonWindow = weekly.filter { $0.weekStart >= comparisonStart && $0.weekStart <= comparisonEnd }
            guard let baseline = aggregateWeeklyWindow(baselineWindow),
                  let latest = aggregateWeeklyWindow(comparisonWindow) else {
                return nil
            }
            return (baseline, latest)
        }

        // Backward-compatible fallback
        guard weekly.count >= 2, let first = weekly.first, let last = weekly.last else {
            return nil
        }
        return (first, last)
    }

    private func aggregateWeeklyWindow(_ weeks: [WeeklyAggregate]) -> WeeklyAggregate? {
        guard let first = weeks.first, let last = weeks.last, !weeks.isEmpty else { return nil }
        let dayCount = weeks.reduce(0) { $0 + $1.dayCount }
        guard dayCount > 0 else { return nil }
        let weightedSum = weeks.reduce(0.0) { $0 + ($1.average * Double($1.dayCount)) }
        let average = weightedSum / Double(dayCount)
        return WeeklyAggregate(
            weekStart: first.weekStart,
            weekEnd: last.weekEnd,
            average: average,
            dayCount: dayCount
        )
    }

    private func loadStorjDailySummaries(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [String: DailySummary] {
        let now = Date()
        if cachedStorjWalletAddress == walletAddress,
           let cached = cachedStorjDailySummaries,
           let loadedAt = cachedStorjLoadedAt,
           now.timeIntervalSince(loadedAt) < 300 {
            return cached
        }

        let items = try await api.listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: "apple-health-full-export"
        )
        .sorted { $0.uploadedAt < $1.uploadedAt }

        var merged: [String: DailySummary] = [:]
        for item in items {
            do {
                let payload = try await api.retrieveHealthData(
                    storjUri: item.uri,
                    walletAddress: walletAddress,
                    encryptionKey: encryptionKey
                )
                for (day, summary) in payload.dailySummaries {
                    merged[day] = summary
                }
            } catch {
                continue
            }
        }

        if merged.isEmpty {
            throw ProofError.insufficientData
        }

        cachedStorjWalletAddress = walletAddress
        cachedStorjDailySummaries = merged
        cachedStorjLoadedAt = now
        return merged
    }

    private func metricValue(for metricID: String, from summary: DailySummary) -> Double? {
        if metricID == "sleepAnalysis", let minutes = summary.sleep?.total {
            return Double(minutes) / 60.0
        }

        let canonicalMetric = canonicalMetricKey(metricID)
        guard let matched = summary.metrics.first(where: { canonicalMetricKey($0.key) == canonicalMetric })?.value else {
            return nil
        }
        return matched.total ?? matched.avg
    }

    private func canonicalMetricKey(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutTypeIdentifier", with: "workout")
            .lowercased()
    }

    private func computeWeeklyAverages(from dailyPoints: [(date: Date, value: Double)]) -> [WeeklyAggregate] {
        var grouped: [Date: [Double]] = [:]
        let calendar = Calendar(identifier: .gregorian)

        for point in dailyPoints {
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: point.date)
            guard let weekStart = calendar.date(from: components) else { continue }
            grouped[weekStart, default: []].append(point.value)
        }

        return grouped
            .compactMap { weekStart, values in
                guard values.count >= 4 else { return nil }
                let average = values.reduce(0, +) / Double(values.count)
                let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
                return WeeklyAggregate(
                    weekStart: weekStart,
                    weekEnd: weekEnd,
                    average: average,
                    dayCount: values.count
                )
            }
            .sorted { $0.weekStart < $1.weekStart }
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

private struct WeeklyAggregate {
    let weekStart: Date
    let weekEnd: Date
    let average: Double
    let dayCount: Int
}
