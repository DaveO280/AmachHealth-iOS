// HealthContextBuilder.swift
// AmachHealth
//
// Builds AIChatContext from DashboardService's cached data.
// No HealthKit queries — uses what's already fetched.

import Foundation

@MainActor
struct HealthContextBuilder {

    // MARK: - Lab Context

    /// Build lab data context for Luma: bloodwork, DEXA, and recent timeline events.
    /// Reads timeline events from cache (free), then fetches the most recent bloodwork
    /// and DEXA records from Storj (requires wallet connection).
    static func buildLabContext() async -> LabDataContext? {
        let wallet = WalletService.shared
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // Always include recent timeline events — they're already cached locally
        let recentEvents = buildTimelineEventSummaries(formatter: formatter)

        // Lab records require a wallet connection and a valid encryption key
        guard wallet.isConnected else {
            if recentEvents.isEmpty { return nil }
            return LabDataContext(bloodwork: nil, dexa: nil, recentEvents: recentEvents)
        }

        let api = AmachAPIClient.shared

        // Use ensureEncryptionKey so an expired key is refreshed automatically
        guard let encryptionKey = try? await wallet.ensureEncryptionKey() else {
            if recentEvents.isEmpty { return nil }
            return LabDataContext(bloodwork: nil, dexa: nil, recentEvents: recentEvents)
        }

        let walletAddress = encryptionKey.walletAddress

        // listLabRecords handles all stored data types: "bloodwork", "dexa",
        // "bloodwork-report-fhir", "dexa-report-fhir", plus a catch-all fallback.
        guard let allLabItems = try? await api.listLabRecords(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        ) else {
            if recentEvents.isEmpty { return nil }
            return LabDataContext(bloodwork: nil, dexa: nil, recentEvents: recentEvents)
        }

        print("🧪 [LabContext] listLabRecords returned \(allLabItems.count) items: \(allLabItems.map { $0.dataType })")

        let bloodworkItems = allLabItems.filter {
            $0.dataType == "bloodwork" || $0.dataType == "bloodwork-report-fhir"
        }
        let dexaItems = allLabItems.filter {
            $0.dataType == "dexa" || $0.dataType == "dexa-report-fhir"
        }

        async let bloodworkResult = fetchLatestBloodwork(
            items: bloodworkItems,
            api: api,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            formatter: formatter
        )
        async let dexaResult = fetchLatestDexa(
            items: dexaItems,
            api: api,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            formatter: formatter
        )

        let (bloodwork, dexa) = await (bloodworkResult, dexaResult)

        let bloodworkList = bloodwork.map { [$0] }
        let dexaList = dexa.map { [$0] }

        let hasData = bloodworkList != nil || dexaList != nil || !recentEvents.isEmpty
        guard hasData else { return nil }

        return LabDataContext(
            bloodwork: bloodworkList,
            dexa: dexaList,
            recentEvents: recentEvents.isEmpty ? nil : recentEvents
        )
    }

    /// Pull the most recent timeline events from the in-memory cache.
    private static func buildTimelineEventSummaries(formatter: DateFormatter) -> [TimelineEventSummary] {
        let events = TimelineService.shared.events
            .filter { !$0.isAnomaly }  // anomalies are captured elsewhere; focus on user-entered events
            .prefix(8)                 // cap at 8 most recent to keep prompt size manageable

        return events.compactMap { event -> TimelineEventSummary? in
            let summary = event.subtitleText ?? event.titleText
            guard !summary.isEmpty else { return nil }
            return TimelineEventSummary(
                date: formatter.string(from: event.timestamp),
                type: event.eventType.displayName,
                summary: "\(event.titleText): \(summary)"
            )
        }
    }

    // Fetch most recent bloodwork record from pre-filtered list items
    private static func fetchLatestBloodwork(
        items: [StorjListItem],
        api: AmachAPIClient,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        formatter: DateFormatter
    ) async -> LabResultSummary? {
        guard let latest = items.max(by: { $0.uploadedAt < $1.uploadedAt }) else { return nil }
        do {
            if latest.dataType == "bloodwork-report-fhir" {
                let report = try await api.retrieveBloodworkReport(
                    storjUri: latest.uri,
                    walletAddress: walletAddress,
                    encryptionKey: encryptionKey
                )
                return labResultSummary(fromReport: report, formatter: formatter)
            } else {
                let record = try await api.retrieveStoredData(
                    storjUri: latest.uri,
                    walletAddress: walletAddress,
                    encryptionKey: encryptionKey,
                    as: LabRecord.self
                )
                return labResultSummary(from: record, formatter: formatter)
            }
        } catch {
            print("🧪 [LabContext] bloodwork fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    // Fetch most recent DEXA record from pre-filtered list items
    private static func fetchLatestDexa(
        items: [StorjListItem],
        api: AmachAPIClient,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        formatter: DateFormatter
    ) async -> DexaResultSummary? {
        guard let latest = items.max(by: { $0.uploadedAt < $1.uploadedAt }) else { return nil }
        do {
            if latest.dataType == "dexa-report-fhir" {
                let report = try await api.retrieveDexaReport(
                    storjUri: latest.uri,
                    walletAddress: walletAddress,
                    encryptionKey: encryptionKey
                )
                return dexaResultSummary(fromReport: report, formatter: formatter)
            } else {
                let record = try await api.retrieveStoredData(
                    storjUri: latest.uri,
                    walletAddress: walletAddress,
                    encryptionKey: encryptionKey,
                    as: LabRecord.self
                )
                return dexaResultSummary(from: record, formatter: formatter)
            }
        } catch {
            print("🧪 [LabContext] dexa fetch error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Summary builders from legacy LabRecord

    private static func labResultSummary(from record: LabRecord, formatter: DateFormatter) -> LabResultSummary {
        let v = record.values
        let knownKeys: Set<String> = ["glucose", "hba1c", "HbA1c", "totalCholesterol", "cholesterol",
                                      "ldl", "LDL", "hdl", "HDL", "triglycerides", "tsh", "TSH",
                                      "vitaminD", "vitamin_d", "ferritin"]
        let additional = v.filter { !knownKeys.contains($0.key) }
        return LabResultSummary(
            date: formatter.string(from: record.date),
            glucose: v["glucose"],
            hba1c: v["hba1c"] ?? v["HbA1c"],
            totalCholesterol: v["totalCholesterol"] ?? v["cholesterol"],
            ldl: v["ldl"] ?? v["LDL"],
            hdl: v["hdl"] ?? v["HDL"],
            triglycerides: v["triglycerides"],
            tsh: v["tsh"] ?? v["TSH"],
            vitaminD: v["vitaminD"] ?? v["vitamin_d"],
            ferritin: v["ferritin"],
            notes: record.notes,
            additionalMetrics: additional.isEmpty ? nil : additional
        )
    }

    private static func dexaResultSummary(from record: LabRecord, formatter: DateFormatter) -> DexaResultSummary {
        let v = record.values
        return DexaResultSummary(
            date: formatter.string(from: record.date),
            bodyFatPercent: v["bodyFatPercent"] ?? v["body_fat"],
            leanMassKg: v["leanMass"] ?? v["leanMassKg"],
            boneDensityTScore: v["boneDensityTScore"] ?? v["tScore"],
            visceralFat: v["visceralFat"],
            androidGynoidRatio: v["androidGynoidRatio"],
            notes: record.notes
        )
    }

    // MARK: - Summary builders from FHIR reports (uploaded via web app)

    private static func labResultSummary(fromReport report: RemoteBloodworkReport, formatter: DateFormatter) -> LabResultSummary {
        // Build a lookup: metric name (lowercased) → value
        var v: [String: Double] = [:]
        for metric in report.metrics {
            if let value = metric.value {
                v[metric.name.lowercased()] = value
            }
        }
        func find(_ keys: String...) -> Double? { keys.compactMap { v[$0] }.first }

        let dateStr = report.reportDate ?? formatter.string(from: Date())

        // Named fields cover the most common markers
        let namedKeys: Set<String> = [
            "glucose", "fasting glucose", "blood glucose",
            "hba1c", "hemoglobin a1c", "a1c",
            "total cholesterol", "cholesterol",
            "ldl", "ldl cholesterol", "ldl-c",
            "hdl", "hdl cholesterol", "hdl-c",
            "triglycerides", "triglyceride",
            "tsh", "thyroid stimulating hormone",
            "vitamin d", "25-oh vitamin d", "25-hydroxyvitamin d", "vitamin d, 25-oh",
            "ferritin"
        ]

        // Pass through everything else so no metric gets dropped
        let additional: [String: Double] = v.filter { !namedKeys.contains($0.key) }

        return LabResultSummary(
            date: dateStr,
            glucose: find("glucose", "fasting glucose", "blood glucose"),
            hba1c: find("hba1c", "hemoglobin a1c", "a1c"),
            totalCholesterol: find("total cholesterol", "cholesterol"),
            ldl: find("ldl", "ldl cholesterol", "ldl-c"),
            hdl: find("hdl", "hdl cholesterol", "hdl-c"),
            triglycerides: find("triglycerides", "triglyceride"),
            tsh: find("tsh", "thyroid stimulating hormone"),
            vitaminD: find("vitamin d", "25-oh vitamin d", "25-hydroxyvitamin d", "vitamin d, 25-oh"),
            ferritin: find("ferritin"),
            notes: nil,
            additionalMetrics: additional.isEmpty ? nil : additional
        )
    }

    private static func dexaResultSummary(fromReport report: RemoteDexaReport, formatter: DateFormatter) -> DexaResultSummary {
        let dateStr = report.scanDate ?? formatter.string(from: Date())
        return DexaResultSummary(
            date: dateStr,
            bodyFatPercent: report.totalBodyFatPercent,
            leanMassKg: report.totalLeanMassKg,
            boneDensityTScore: report.boneDensityTotal?.tScore,
            visceralFat: report.visceralFatAreaCm2 ?? report.visceralFatRating,
            androidGynoidRatio: report.androidGynoidRatio,
            notes: nil  // omit notes — PDF filenames add bulk without clinical value
        )
    }

    /// Build chat context from the dashboard's cached today data + trends.
    /// Returns nil if no meaningful data is available.
    static func buildCurrentContext() -> AIChatContext? {
        let dashboard = DashboardService.shared
        let today = dashboard.today

        // If nothing is loaded yet, return nil — Luma will work without context
        guard today.steps > 0 || today.heartRateAvg > 0 || today.sleepHours > 0 else {
            return nil
        }

        let metrics = AIChatMetrics(
            steps: MetricContext(
                average: monthAverage(dashboard.stepsTrend),
                min: monthMin(dashboard.stepsTrend),
                max: monthMax(dashboard.stepsTrend),
                latest: today.steps > 0 ? today.steps : nil,
                trend: computeTrend(dashboard.stepsTrend)
            ),
            heartRate: MetricContext(
                average: monthAverage(dashboard.heartRateTrend),
                min: monthMin(dashboard.heartRateTrend),
                max: monthMax(dashboard.heartRateTrend),
                latest: today.heartRateAvg > 0 ? today.heartRateAvg : nil,
                trend: computeTrend(dashboard.heartRateTrend)
            ),
            hrv: MetricContext(
                average: monthAverage(dashboard.hrvTrend),
                min: monthMin(dashboard.hrvTrend),
                max: monthMax(dashboard.hrvTrend),
                latest: today.hrv > 0 ? today.hrv : nil,
                trend: computeTrend(dashboard.hrvTrend)
            ),
            sleep: MetricContext(
                average: monthAverage(dashboard.sleepTrend),
                min: monthMin(dashboard.sleepTrend),
                max: monthMax(dashboard.sleepTrend),
                latest: today.sleepHours > 0 ? today.sleepHours : nil,
                trend: computeTrend(dashboard.sleepTrend)
            ),
            exercise: MetricContext(
                average: monthAverage(dashboard.calsTrend),
                min: nil,
                max: nil,
                latest: today.exerciseMinutes > 0 ? today.exerciseMinutes : nil,
                trend: computeTrend(dashboard.calsTrend)
            ),
            restingHeartRate: today.restingHeartRate > 0 ? MetricContext(
                average: nil, min: nil, max: nil,
                latest: today.restingHeartRate,
                trend: nil
            ) : nil,
            vo2Max: today.vo2Max > 0 ? MetricContext(
                average: nil, min: nil, max: nil,
                latest: today.vo2Max,
                trend: nil
            ) : nil,
            respiratoryRate: today.respiratoryRate > 0 ? MetricContext(
                average: nil, min: nil, max: nil,
                latest: today.respiratoryRate,
                trend: nil
            ) : nil,
            recoveryScore: today.recoveryScore?.score,
            sleepDeepHours: sleepStageMetric(
                from: dashboard.sleepStagesTrend,
                keyPath: \.deepHours
            ),
            sleepRemHours: sleepStageMetric(
                from: dashboard.sleepStagesTrend,
                keyPath: \.remHours
            )
        )

        let formatter = ISO8601DateFormatter()
        let now = Date()
        let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)!

        return AIChatContext(
            metrics: metrics,
            dateRange: AIChatDateRange(
                start: formatter.string(from: monthAgo),
                end: formatter.string(from: now)
            )
        )
    }

    // MARK: - Intent-aware context (smart routing)

    /// Build context for the given intent and mode. buildCurrentContext() is left untouched.
    /// Quick: subset of metrics + intent-relevant blocks. Deep: all metrics + all blocks.
    static func buildContext(for intent: ChatIntent, mode: ChatMode) -> AIChatContext? {
        let dashboard = DashboardService.shared
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let dateRange = AIChatDateRange(
            start: formatter.string(from: monthAgo),
            end: formatter.string(from: now)
        )

        if mode == .deep {
            let full = buildCurrentContext()
            var blocks: [AIChatContextBlock] = []
            if let hr = buildHRZonesBlock() { blocks.append(hr) }
            if let w = buildWorkoutsBlock() { blocks.append(w) }
            if let a = buildAnomaliesBlock() { blocks.append(a) }
            return AIChatContext(
                metrics: full?.metrics,
                dateRange: dateRange,
                proactive: nil,
                memory: nil,
                userAddress: nil,
                encryptionKey: nil,
                labData: nil,
                contextBlocks: blocks.isEmpty ? nil : blocks
            )
        }

        // Quick: intent-based subset
        let full = buildCurrentContext()
        let metricsFiltered = full?.metrics.flatMap { filterMetrics($0, to: intent.metricKeys) }
        var blocks: [AIChatContextBlock] = []
        if intent.includesHRZones, let hr = buildHRZonesBlock() { blocks.append(hr) }
        if intent.includesWorkouts, let w = buildWorkoutsBlock() { blocks.append(w) }
        if intent.includesAnomalies, let a = buildAnomaliesBlock() { blocks.append(a) }

        return AIChatContext(
            metrics: metricsFiltered ?? full?.metrics,
            dateRange: dateRange,
            proactive: nil,
            memory: nil,
            userAddress: nil,
            encryptionKey: nil,
            labData: nil,
            contextBlocks: blocks.isEmpty ? nil : blocks
        )
    }

    /// Filter metrics to only include the given keys (e.g. sleep, hrv, restingHeartRate for .sleep).
    private static func filterMetrics(_ m: AIChatMetrics, to keys: Set<String>) -> AIChatMetrics? {
        AIChatMetrics(
            steps: keys.contains("steps") ? m.steps : nil,
            heartRate: keys.contains("heartRate") ? m.heartRate : nil,
            hrv: keys.contains("hrv") ? m.hrv : nil,
            sleep: keys.contains("sleep") ? m.sleep : nil,
            exercise: keys.contains("exercise") ? m.exercise : nil,
            restingHeartRate: keys.contains("restingHeartRate") ? m.restingHeartRate : nil,
            vo2Max: keys.contains("vo2Max") ? m.vo2Max : nil,
            respiratoryRate: keys.contains("respiratoryRate") ? m.respiratoryRate : nil,
            recoveryScore: keys.contains("recoveryScore") ? m.recoveryScore : nil,
            sleepDeepHours: keys.contains("sleepDeepHours") ? m.sleepDeepHours : nil,
            sleepRemHours: keys.contains("sleepRemHours") ? m.sleepRemHours : nil
        )
    }

    private static func buildHRZonesBlock() -> AIChatContextBlock? {
        let dashboard = DashboardService.shared
        let zones = dashboard.hrZonesTrend[.month] ?? dashboard.todayHRZones
        guard zones.total > 0 else { return nil }
        let totalMin = zones.total
        let lines = [
            "Heart rate zones (training):",
            String(format: "  Zone 1 (recovery): %.0f min (%.0f%%)", zones.zone1, zones.fraction(for: 1) * 100),
            String(format: "  Zone 2 (fat burn): %.0f min (%.0f%%)", zones.zone2, zones.fraction(for: 2) * 100),
            String(format: "  Zone 3 (aerobic): %.0f min (%.0f%%)", zones.zone3, zones.fraction(for: 3) * 100),
            String(format: "  Zone 4 (threshold): %.0f min (%.0f%%)", zones.zone4, zones.fraction(for: 4) * 100),
            String(format: "  Zone 5 (peak): %.0f min (%.0f%%)", zones.zone5, zones.fraction(for: 5) * 100),
            String(format: "  Total: %.0f min", totalMin)
        ]
        return AIChatContextBlock(type: "hr_zones", content: lines.joined(separator: "\n"))
    }

    private static func buildWorkoutsBlock() -> AIChatContextBlock? {
        let items = DashboardService.shared.recentWorkoutSummaries
        guard !items.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let lines = ["Recent workouts (last 7 days):"] + items.prefix(14).map { w in
            "  \(formatter.string(from: w.date)): \(w.activityType) \(Int(w.durationMinutes)) min"
        }
        return AIChatContextBlock(type: "workouts", content: lines.joined(separator: "\n"))
    }

    private static func buildAnomaliesBlock() -> AIChatContextBlock? {
        let anomalies = TimelineService.shared.events.filter(\.isAnomaly).prefix(10)
        guard !anomalies.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let lines = ["Recent auto-detected anomalies:"] + anomalies.map { e in
            "  \(formatter.string(from: e.timestamp)): \(e.titleText)\(e.subtitleText.map { " — \($0)" } ?? "")"
        }
        return AIChatContextBlock(type: "anomalies", content: lines.joined(separator: "\n"))
    }

    // MARK: - Trend Computation

    /// Compare recent half of 30-day data to prior half.
    /// Returns "improving", "stable", or "declining".
    private static func computeTrend(_ trendData: [TrendPeriod: [TrendPoint]]) -> String? {
        guard let monthData = trendData[.month], monthData.count >= 10 else {
            return nil
        }

        let sorted = monthData.sorted { $0.date < $1.date }
        let midpoint = sorted.count / 2
        let recentHalf = sorted.suffix(from: midpoint)
        let priorHalf = sorted.prefix(upTo: midpoint)

        guard !recentHalf.isEmpty, !priorHalf.isEmpty else { return nil }

        let recentAvg = recentHalf.map(\.value).reduce(0, +) / Double(recentHalf.count)
        let priorAvg = priorHalf.map(\.value).reduce(0, +) / Double(priorHalf.count)

        guard priorAvg > 0 else { return "stable" }
        let changePct = ((recentAvg - priorAvg) / priorAvg) * 100

        if changePct > 5 { return "improving" }
        if changePct < -5 { return "declining" }
        return "stable"
    }

    // MARK: - Helpers

    private static func monthAverage(_ trendData: [TrendPeriod: [TrendPoint]]) -> Double? {
        guard let data = trendData[.month], !data.isEmpty else { return nil }
        return data.map(\.value).reduce(0, +) / Double(data.count)
    }

    private static func monthMin(_ trendData: [TrendPeriod: [TrendPoint]]) -> Double? {
        trendData[.month]?.map(\.value).min()
    }

    private static func monthMax(_ trendData: [TrendPeriod: [TrendPoint]]) -> Double? {
        trendData[.month]?.map(\.value).max()
    }

    private static func sleepStageMetric(
        from trend: [TrendPeriod: [SleepStageTrendPoint]],
        keyPath: KeyPath<SleepStageTrendPoint, Double>
    ) -> MetricContext? {
        guard let data = trend[.month], !data.isEmpty else { return nil }
        let values = data.map { $0[keyPath: keyPath] }
        guard values.contains(where: { $0 > 0 }) else { return nil }

        let avg = values.reduce(0, +) / Double(values.count)
        let min = values.min()
        let max = values.max()
        let latest = data.last?[keyPath: keyPath]

        return MetricContext(
            average: avg,
            min: min,
            max: max,
            latest: latest,
            trend: computeTrend(
                // Reuse TrendPoint-based trend by projecting hours into generic points
                [.month: data.map { TrendPoint(date: $0.date, value: $0[keyPath: keyPath]) }]
            )
        )
    }
}
