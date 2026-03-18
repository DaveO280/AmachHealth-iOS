// HealthContextBuilder.swift
// AmachHealth
//
// Builds AIChatContext from DashboardService's cached data.
// No HealthKit queries — uses what's already fetched.
//
// Data contract for Luma:
//   • latest     = previous complete day's value (never today's partial)
//   • sevenDayAvg = 7-day rolling average of completed days
//   • average    = 30-day average of completed days
//
// This prevents Luma from commenting on partial-day accumulations
// (e.g. low step count at 8am) unless the user explicitly asks.
//
// Context is delivered as typed ContextBlock items — iOS owns all formatting,
// the backend loops through blocks and injects each verbatim as a system message.
// Adding a new data source = new block here, zero backend changes needed.

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

        // Warm cache (TTL-backed) once per session / when stale.
        await LabContextService.shared.load(wallet: wallet)

        let cached = LabContextService.shared.context
        let bloodworkSummary = cached.map { labResultSummary(from: $0.bloodwork, formatter: formatter) }
            .flatMap { $0 }
        let dexaSummary = cached.map { dexaResultSummary(from: $0.dexa, formatter: formatter) }
            .flatMap { $0 }

        let hasData = bloodworkSummary != nil || dexaSummary != nil || !recentEvents.isEmpty
        guard hasData else { return nil }

        return LabDataContext(
            bloodwork: bloodworkSummary.map { [$0] },
            dexa: dexaSummary.map { [$0] },
            recentEvents: recentEvents.isEmpty ? nil : recentEvents
        )
    }

    private static func labResultSummary(
        from ctx: LabBloodworkContext?,
        formatter: DateFormatter
    ) -> LabResultSummary? {
        guard let ctx else { return nil }
        guard !ctx.metrics.isEmpty else { return nil }

        // Normalize metric names for keyword matching.
        func norm(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var usedMetricNames = Set<String>()
        func matchValue(_ keywords: [String]) -> Double? {
            for m in ctx.metrics {
                guard let v = m.value else { continue }
                let name = norm(m.name)
                for kw in keywords {
                    let nkw = norm(kw)
                    if name == nkw || name.contains(nkw) {
                        usedMetricNames.insert(name)
                        return v
                    }
                }
            }
            return nil
        }

        func notesString(_ notes: [String]?) -> String? {
            guard let notes else { return nil }
            let joined = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            return joined.isEmpty ? nil : joined
        }

        // Named fields (keep ordering stable by matching in metric-list order)
        let glucose = matchValue(["glucose", "fasting glucose", "blood glucose"])
        let hba1c = matchValue(["hba1c", "hemoglobin a1c", "a1c"])
        let totalCholesterol = matchValue(["total cholesterol", "cholesterol"])
        let ldl = matchValue(["ldl-c", "ldl cholesterol", "ldl"])
        let hdl = matchValue(["hdl-c", "hdl cholesterol", "hdl"])
        let triglycerides = matchValue(["triglycerides", "triglyceride", "triglycerides"])
        let tsh = matchValue(["tsh", "thyroid stimulating hormone"])
        let vitaminD = matchValue(["vitamin d", "25-oh vitamin d", "25-hydroxyvitamin d", "vitamin_d"])
        let ferritin = matchValue(["ferritin"])

        // Additional metrics: everything numeric we didn't map into named fields.
        var additional: [String: Double] = [:]
        for m in ctx.metrics {
            guard let v = m.value else { continue }
            let name = norm(m.name)
            guard !usedMetricNames.contains(name) else { continue }
            additional[name] = v
        }
        let limitedAdditional = additional
            .sorted { $0.key < $1.key }
            .prefix(8)
            .reduce(into: [String: Double]()) { $0[$1.key] = $1.value }
        let additionalMetrics = limitedAdditional.isEmpty ? nil : limitedAdditional

        let dateStr = ctx.reportDate ?? formatter.string(from: Date())

        return LabResultSummary(
            date: dateStr,
            glucose: glucose,
            hba1c: hba1c,
            totalCholesterol: totalCholesterol,
            ldl: ldl,
            hdl: hdl,
            triglycerides: triglycerides,
            tsh: tsh,
            vitaminD: vitaminD,
            ferritin: ferritin,
            notes: notesString(ctx.notes),
            additionalMetrics: additionalMetrics
        )
    }

    private static func dexaResultSummary(
        from ctx: LabDexaContext?,
        formatter: DateFormatter
    ) -> DexaResultSummary? {
        guard let ctx else { return nil }

        func notesString(_ notes: [String]?) -> String? {
            guard let notes else { return nil }
            let joined = notes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            return joined.isEmpty ? nil : joined
        }

        return DexaResultSummary(
            date: ctx.scanDate ?? formatter.string(from: Date()),
            bodyFatPercent: ctx.bodyFatPercent,
            leanMassKg: ctx.leanMassKg,
            boneDensityTScore: ctx.boneDensityTScore,
            boneDensityZScore: ctx.boneDensityZScore,
            visceralFat: ctx.visceralFatRating,
            androidGynoidRatio: ctx.androidGynoidRatio,
            notes: notesString(ctx.notes)
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
            boneDensityZScore: v["boneDensityZScore"] ?? v["zScore"],
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
            boneDensityZScore: report.boneDensityTotal?.zScore,
            visceralFat: report.visceralFatAreaCm2 ?? report.visceralFatRating,
            androidGynoidRatio: report.androidGynoidRatio,
            notes: nil  // omit notes — PDF filenames add bulk without clinical value
        )
    }

    private static let dataNote = """
        Metrics reflect completed calendar days only. \
        'latest' is yesterday's full-day value; \
        'sevenDayAvg' is the 7-day rolling average of completed days. \
        Never comment on today's partial-day accumulations (steps, calories, exercise) \
        unless the user specifically asks about today. \
        For time-sensitive questions like comparing a workout HRV to similar workouts, \
        use the trend data the user provides in their message.
        """

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
                latest: previousDayValue(dashboard.stepsTrend),
                sevenDayAvg: weekAverage(dashboard.stepsTrend),
                trend: computeTrend(dashboard.stepsTrend)
            ),
            heartRate: MetricContext(
                average: monthAverage(dashboard.heartRateTrend),
                min: monthMin(dashboard.heartRateTrend),
                max: monthMax(dashboard.heartRateTrend),
                latest: previousDayValue(dashboard.heartRateTrend),
                sevenDayAvg: weekAverage(dashboard.heartRateTrend),
                trend: computeTrend(dashboard.heartRateTrend)
            ),
            hrv: MetricContext(
                average: monthAverage(dashboard.hrvTrend),
                min: monthMin(dashboard.hrvTrend),
                max: monthMax(dashboard.hrvTrend),
                latest: previousDayValue(dashboard.hrvTrend),
                sevenDayAvg: weekAverage(dashboard.hrvTrend),
                trend: computeTrend(dashboard.hrvTrend)
            ),
            sleep: MetricContext(
                average: monthAverage(dashboard.sleepTrend),
                min: monthMin(dashboard.sleepTrend),
                max: monthMax(dashboard.sleepTrend),
                // Sleep is already last night's completed data — use directly
                latest: today.sleepHours > 0 ? today.sleepHours : previousDayValue(dashboard.sleepTrend),
                sevenDayAvg: weekAverage(dashboard.sleepTrend),
                trend: computeTrend(dashboard.sleepTrend)
            ),
            exercise: MetricContext(
                average: monthAverage(dashboard.exerciseTrend),
                min: nil,
                max: nil,
                latest: previousDayValue(dashboard.exerciseTrend),
                sevenDayAvg: weekAverage(dashboard.exerciseTrend),
                trend: computeTrend(dashboard.exerciseTrend)
            ),
            restingHeartRate: today.restingHeartRate > 0 ? MetricContext(
                average: monthAverage(dashboard.rhrTrend),
                min: nil,
                max: nil,
                // RHR is a resting/morning measurement — today's reading is valid
                latest: today.restingHeartRate,
                sevenDayAvg: weekAverage(dashboard.rhrTrend),
                trend: computeTrend(dashboard.rhrTrend)
            ) : nil,
            vo2Max: today.vo2Max > 0 ? MetricContext(
                average: nil, min: nil, max: nil,
                latest: today.vo2Max,
                sevenDayAvg: weekAverage(dashboard.vo2Trend),
                trend: nil
            ) : nil,
            respiratoryRate: today.respiratoryRate > 0 ? MetricContext(
                average: nil, min: nil, max: nil,
                latest: previousDayValue(dashboard.rrTrend) ?? today.respiratoryRate,
                sevenDayAvg: weekAverage(dashboard.rrTrend),
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
        let dateRange = AIChatDateRange(
            start: formatter.string(from: monthAgo),
            end: formatter.string(from: now)
        )

        // --- Assemble context blocks ---
        var blocks: [ContextBlock] = []

        // 1. data_note — partial-day instruction (always first)
        blocks.append(ContextBlock(type: "data_note", content: dataNote))

        // 2. metrics — formatted health metrics text
        blocks.append(ContextBlock(type: "metrics", content: formatMetrics(metrics, dateRange: dateRange)))

        // 3. labs_bloodwork + labs_dexa — separate blocks for targeted queries
        if let labs = LabContextService.shared.context {
            if let bw = labs.bloodwork {
                blocks.append(ContextBlock(type: "labs_bloodwork", content: formatBloodwork(bw)))
            }
            if let dx = labs.dexa {
                blocks.append(ContextBlock(type: "labs_dexa", content: formatDexa(dx)))
            }
        }

        // 4. goals — conversation-extracted active goals (separate from memory for clarity)
        let goalFacts = ConversationMemoryStore.shared.facts
            .filter { $0.category == .goal && $0.isActive }
            .map(\.value)
        if !goalFacts.isEmpty {
            let content = "User's health goals:\n" + goalFacts.map { "  • \($0)" }.joined(separator: "\n")
            blocks.append(ContextBlock(type: "goals", content: content))
        }

        // 5. memory — concerns, medications, conditions, session notes
        if let mem = ConversationMemoryStore.shared.buildMemoryCapsule() {
            blocks.append(ContextBlock(type: "memory", content: formatMemory(mem)))
        }

        // 6. timeline — active meds, conditions, allergies, recent anomalies
        let timelineContent = formatTimeline(TimelineService.shared.events)
        if !timelineContent.isEmpty {
            blocks.append(ContextBlock(type: "timeline", content: timelineContent))
        }

        #if DEBUG
        print("🧠 HealthContextBuilder: assembled \(blocks.count) context blocks: \(blocks.map(\.type).joined(separator: ", "))")
        #endif

        return AIChatContext(
            metrics: metrics,
            dateRange: dateRange,
            contextBlocks: blocks
        )
    }

    // MARK: - Intent-aware context (smart routing)

    /// Build context for the given intent and mode.
    /// Starts from buildCurrentContext()'s blocks — data_note, metrics, labs, timeline —
    /// and layers in intent-specific extras (hr_zones, workouts, anomalies).
    /// Goals and memory blocks are excluded here since enrichContext() injects them
    /// via the AIChatMemoryCapsule to avoid duplication.
    static func buildContext(for intent: ChatIntent, mode: ChatMode) -> AIChatContext? {
        let full = buildCurrentContext()
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let dateRange = AIChatDateRange(
            start: formatter.string(from: monthAgo),
            end: formatter.string(from: now)
        )

        // Start with base blocks, excluding goals/memory (handled by enrichContext)
        var blocks: [ContextBlock] = (full?.contextBlocks ?? []).filter { block in
            block.type != "goals" && block.type != "memory"
        }

        // In quick mode, prune blocks not relevant to the intent
        if mode == .quick {
            if !intent.includesLabData {
                blocks.removeAll { $0.type == "labs_bloodwork" || $0.type == "labs_dexa" }
            }
            if !intent.includesTimelineEvents {
                blocks.removeAll { $0.type == "timeline" }
            }
        }

        // Layer in intent-specific extras
        if mode == .deep || intent.includesHRZones {
            if let hr = buildHRZonesBlock() { blocks.append(hr) }
        }
        if mode == .deep || intent.includesWorkouts {
            if let w = buildWorkoutsBlock() { blocks.append(w) }
        }
        if mode == .deep || intent.includesAnomalies {
            if let a = buildAnomaliesBlock() { blocks.append(a) }
        }

        let metricsToUse: AIChatMetrics?
        if mode == .deep {
            metricsToUse = full?.metrics
        } else {
            metricsToUse = full?.metrics.flatMap { filterMetrics($0, to: intent.metricKeys) }
        }

        return AIChatContext(
            metrics: metricsToUse ?? full?.metrics,
            dateRange: dateRange,
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

    private static func buildHRZonesBlock() -> ContextBlock? {
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
        return ContextBlock(type: "hr_zones", content: lines.joined(separator: "\n"))
    }

    private static func buildWorkoutsBlock() -> ContextBlock? {
        let items = DashboardService.shared.recentWorkoutSummaries
        guard !items.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let lines = ["Recent workouts (last 7 days):"] + items.prefix(14).map { w in
            "  \(formatter.string(from: w.date)): \(w.activityType) \(Int(w.durationMinutes)) min"
        }
        return ContextBlock(type: "workouts", content: lines.joined(separator: "\n"))
    }

    private static func buildAnomaliesBlock() -> ContextBlock? {
        let anomalies = TimelineService.shared.events.filter(\.isAnomaly).prefix(10)
        guard !anomalies.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let lines = ["Recent auto-detected anomalies:"] + anomalies.map { e in
            "  \(formatter.string(from: e.timestamp)): \(e.titleText)\(e.subtitleText.map { " — \($0)" } ?? "")"
        }
        return ContextBlock(type: "anomalies", content: lines.joined(separator: "\n"))
    }

    // MARK: - Block Formatters (used by buildCurrentContext)
    private static func formatMetrics(_ m: AIChatMetrics, dateRange: AIChatDateRange) -> String {
        var parts: [String] = []
        parts.append("Health metrics (latest = previous full day, sevenDayAvg = 7-day rolling average):")

        if let s = m.steps {
            let latest = s.latest.map { String(format: "%.0f", $0) } ?? "N/A"
            let avg = (s.sevenDayAvg ?? s.average).map { String(format: "%.0f", $0) } ?? "N/A"
            parts.append("- Steps: \(latest) (yesterday), 7-day avg \(avg)/day (trend: \(s.trend ?? "N/A"))")
        }
        if let hr = m.heartRate {
            let latest = hr.latest.map { String(format: "%.0f", $0) } ?? "N/A"
            let avg = (hr.sevenDayAvg ?? hr.average).map { String(format: "%.0f", $0) } ?? "N/A"
            parts.append("- Heart Rate: \(latest) bpm (yesterday), 7-day avg \(avg) bpm")
        }
        if let hrv = m.hrv {
            let latest = hrv.latest.map { String(format: "%.0f", $0) } ?? "N/A"
            let avg = (hrv.sevenDayAvg ?? hrv.average).map { String(format: "%.0f", $0) } ?? "N/A"
            parts.append("- HRV: \(latest) ms (yesterday), 7-day avg \(avg) ms (trend: \(hrv.trend ?? "N/A"))")
        }
        if let sleep = m.sleep {
            let latest = sleep.latest.map { String(format: "%.1f", $0) } ?? "N/A"
            let avg = (sleep.sevenDayAvg ?? sleep.average).map { String(format: "%.1f", $0) } ?? "N/A"
            parts.append("- Sleep: \(latest) hrs last night, 7-day avg \(avg) hrs/night (trend: \(sleep.trend ?? "N/A"))")
        }
        if let deep = m.sleepDeepHours {
            let latest = deep.latest.map { String(format: "%.1f", $0) } ?? "N/A"
            let avg = (deep.sevenDayAvg ?? deep.average).map { String(format: "%.1f", $0) } ?? "N/A"
            parts.append("- Deep sleep: \(latest) hrs last night, avg \(avg) hrs")
        }
        if let rem = m.sleepRemHours {
            let latest = rem.latest.map { String(format: "%.1f", $0) } ?? "N/A"
            let avg = (rem.sevenDayAvg ?? rem.average).map { String(format: "%.1f", $0) } ?? "N/A"
            parts.append("- REM sleep: \(latest) hrs last night, avg \(avg) hrs")
        }
        if let ex = m.exercise {
            let latest = ex.latest.map { String(format: "%.0f", $0) } ?? "N/A"
            let avg = (ex.sevenDayAvg ?? ex.average).map { String(format: "%.0f", $0) } ?? "N/A"
            parts.append("- Exercise: \(latest) mins yesterday, 7-day avg \(avg) mins/day")
        }
        if let rhr = m.restingHeartRate {
            let latest = rhr.latest.map { String(format: "%.0f", $0) } ?? "N/A"
            let avg = (rhr.sevenDayAvg ?? rhr.average).map { String(format: "%.0f", $0) } ?? "N/A"
            parts.append("- Resting Heart Rate: \(latest) bpm, 7-day avg \(avg) bpm")
        }
        if let vo2 = m.vo2Max {
            parts.append("- VO2 Max: \(vo2.latest.map { String(format: "%.1f", $0) } ?? "N/A") mL/kg/min")
        }
        if let rr = m.respiratoryRate {
            parts.append("- Respiratory Rate: \(rr.latest.map { String(format: "%.1f", $0) } ?? "N/A") breaths/min")
        }
        if let rs = m.recoveryScore {
            parts.append("- Recovery Score: \(rs)/100")
        }
        parts.append("Data range: \(dateRange.start) to \(dateRange.end)")
        return parts.joined(separator: "\n")
    }

    private static func formatBloodwork(_ bw: LabBloodworkContext) -> String {
        var lines: [String] = []
        var header = "Bloodwork lab results"
        if let date = bw.reportDate { header += " (\(date))" }
        if let lab = bw.laboratory { header += " — \(lab)" }
        lines.append(header + ":")
        for m in bw.metrics {
            var entry = "  • \(m.name)"
            if let v = m.value { entry += ": \(v)" }
            if let u = m.unit { entry += " \(u)" }
            if let r = m.referenceRange { entry += " [ref: \(r)]" }
            if let f = m.flag, !f.isEmpty { entry += " ⚠️ \(f)" }
            lines.append(entry)
        }
        if let notes = bw.notes, !notes.isEmpty {
            lines.append("  Notes: " + notes.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    private static func formatDexa(_ dx: LabDexaContext) -> String {
        var lines: [String] = []
        var header = "DEXA body composition scan"
        if let date = dx.scanDate { header += " (\(date))" }
        lines.append(header + ":")
        if let v = dx.bodyFatPercent     { lines.append("  • Body fat: \(v)%") }
        if let v = dx.leanMassKg         { lines.append("  • Lean mass: \(v) kg") }
        if let v = dx.visceralFatRating  { lines.append("  • Visceral fat rating: \(v)") }
        if let v = dx.androidGynoidRatio { lines.append("  • Android/Gynoid ratio: \(v)") }
        if let v = dx.boneDensityTScore  { lines.append("  • Bone density T-score: \(v)") }
        if let v = dx.boneDensityZScore  { lines.append("  • Bone density Z-score: \(v)") }
        if let notes = dx.notes, !notes.isEmpty {
            lines.append("  Notes: " + notes.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    private static func formatMemory(_ mem: AIChatMemoryCapsule) -> String {
        var parts: [String] = ["User memory (from prior conversations):"]
        if !mem.activeGoals.isEmpty     { parts.append("Goals: " + mem.activeGoals.joined(separator: "; ")) }
        if !mem.activeConcerns.isEmpty  { parts.append("Concerns: " + mem.activeConcerns.joined(separator: "; ")) }
        if !mem.medications.isEmpty     { parts.append("Medications/supplements: " + mem.medications.joined(separator: "; ")) }
        if !mem.conditions.isEmpty      { parts.append("Conditions: " + mem.conditions.joined(separator: "; ")) }
        if !mem.recentSessionNotes.isEmpty {
            parts.append("Recent conversation notes: " + mem.recentSessionNotes.joined(separator: " | "))
        }
        return parts.joined(separator: "\n")
    }

    /// Formats timeline events relevant to Luma: active medications, supplements,
    /// conditions, allergies, recent anomalies, and significant recent events.
    /// Capped at ~20 items to keep token footprint reasonable.
    private static func formatTimeline(_ events: [TimelineEvent]) -> String {
        guard !events.isEmpty else { return "" }
        let calendar = Calendar.current
        let now = Date()
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!
        let ninetyDaysAgo = calendar.date(byAdding: .day, value: -90, to: now)!

        var lines: [String] = []

        // --- Active medications (started, not stopped) ---
        let stoppedMedNames = Set(
            events.filter { $0.eventType == .medicationStopped }.compactMap { $0.data["name"] }
        )
        let activeMeds = events
            .filter { $0.eventType == .medicationStarted }
            .filter { guard let name = $0.data["name"] else { return false }; return !stoppedMedNames.contains(name) }
        if !activeMeds.isEmpty {
            lines.append("Active medications:")
            for e in activeMeds.prefix(10) {
                var line = "  • \(e.data["name"] ?? "unknown")"
                if let dose = e.data["dosage"], !dose.isEmpty { line += " \(dose)" }
                lines.append(line)
            }
        }

        // --- Active supplements (started, not stopped) ---
        let stoppedSuppNames = Set(
            events.filter { $0.eventType == .supplementStopped }.compactMap { $0.data["name"] }
        )
        let activeSupps = events
            .filter { $0.eventType == .supplementStarted }
            .filter { guard let name = $0.data["name"] else { return false }; return !stoppedSuppNames.contains(name) }
        if !activeSupps.isEmpty {
            lines.append("Active supplements:")
            for e in activeSupps.prefix(10) {
                var line = "  • \(e.data["name"] ?? "unknown")"
                if let dose = e.data["dosage"], !dose.isEmpty { line += " \(dose)" }
                lines.append(line)
            }
        }

        // --- Active conditions (diagnosed, not resolved) ---
        let resolvedConditions = Set(
            events.filter { $0.eventType == .conditionResolved }.compactMap { $0.data["condition"] }
        )
        let activeConditions = events
            .filter { $0.eventType == .conditionDiagnosed }
            .filter { guard let c = $0.data["condition"] else { return false }; return !resolvedConditions.contains(c) }
        if !activeConditions.isEmpty {
            lines.append("Active conditions:")
            for e in activeConditions.prefix(10) {
                lines.append("  • \(e.data["condition"] ?? "unknown")")
            }
        }

        // --- Allergies ---
        let allergies = events.filter { $0.eventType == .allergyAdded }
        if !allergies.isEmpty {
            lines.append("Allergies:")
            for e in allergies.prefix(10) {
                var line = "  • \(e.data["allergen"] ?? "unknown")"
                if let sev = e.data["severity"], !sev.isEmpty { line += " (\(sev))" }
                lines.append(line)
            }
        }

        // --- Recent anomalies (last 30 days) ---
        let recentAnomalies = events
            .filter { $0.isAnomaly && $0.timestamp >= thirtyDaysAgo }
            .sorted { $0.timestamp > $1.timestamp }
        if !recentAnomalies.isEmpty {
            lines.append("Recent health anomalies (last 30 days):")
            let dateFmt = DateFormatter()
            dateFmt.dateStyle = .medium
            dateFmt.timeStyle = .none
            for e in recentAnomalies.prefix(5) {
                let metric = e.metricType ?? "unknown metric"
                let dir = e.direction.map { " (\($0))" } ?? ""
                let dev = e.deviationPct.map { String(format: " %.0f%% vs baseline", $0) } ?? ""
                lines.append("  • \(dateFmt.string(from: e.timestamp)): \(metric) anomaly\(dir)\(dev)")
            }
        }

        // --- Recent significant events (last 90 days) ---
        let significantTypes: Set<TimelineEventType> = [
            .labResults, .surgeryProcedure, .surgeryCompleted, .procedureCompleted,
            .lifestyleChange, .dietChange, .exerciseChange, .custom, .generalNote
        ]
        let recentSignificant = events
            .filter { significantTypes.contains($0.eventType) && $0.timestamp >= ninetyDaysAgo }
            .sorted { $0.timestamp > $1.timestamp }
        if !recentSignificant.isEmpty {
            lines.append("Recent significant events (last 90 days):")
            let dateFmt = DateFormatter()
            dateFmt.dateStyle = .medium
            dateFmt.timeStyle = .none
            for e in recentSignificant.prefix(5) {
                let title = e.titleText
                if let detail = e.subtitleText, !detail.isEmpty, detail != title {
                    lines.append("  • \(dateFmt.string(from: e.timestamp)): \(title) — \(detail)")
                } else {
                    lines.append("  • \(dateFmt.string(from: e.timestamp)): \(title)")
                }
            }
        }

        guard !lines.isEmpty else { return "" }
        lines.insert("User health timeline:", at: 0)
        return lines.joined(separator: "\n")
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

    /// Last complete day's value — excludes today's partial accumulation.
    private static func previousDayValue(_ trendData: [TrendPeriod: [TrendPoint]]) -> Double? {
        guard let data = trendData[.week] ?? trendData[.month], !data.isEmpty else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let completedDays = data.filter { !Calendar.current.isDate($0.date, inSameDayAs: today) }
        return completedDays.sorted { $0.date < $1.date }.last?.value
    }

    /// 7-day rolling average of completed days only (excludes today).
    private static func weekAverage(_ trendData: [TrendPeriod: [TrendPoint]]) -> Double? {
        guard let data = trendData[.week], !data.isEmpty else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let completedDays = data.filter { !Calendar.current.isDate($0.date, inSameDayAs: today) }
        guard !completedDays.isEmpty else { return nil }
        return completedDays.map(\.value).reduce(0, +) / Double(completedDays.count)
    }

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

        // Latest = last night's stage data (already a completed night)
        let latest = data.last?[keyPath: keyPath]

        // 7-day avg from week trend, excluding today
        let weekAvg: Double? = {
            guard let weekData = trend[.week], !weekData.isEmpty else { return nil }
            let today = Calendar.current.startOfDay(for: Date())
            let completed = weekData.filter { !Calendar.current.isDate($0.date, inSameDayAs: today) }
            guard !completed.isEmpty else { return nil }
            let vals = completed.map { $0[keyPath: keyPath] }
            return vals.reduce(0, +) / Double(vals.count)
        }()

        return MetricContext(
            average: avg,
            min: min,
            max: max,
            latest: latest,
            sevenDayAvg: weekAvg,
            trend: computeTrend(
                [.month: data.map { TrendPoint(date: $0.date, value: $0[keyPath: keyPath]) }]
            )
        )
    }
}
