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

        // Lab records live in the vault, which opens from the Keychain even
        // without a live wallet session.
        guard wallet.isConnected || LocalVault.shared.isOpen else {
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
        let hasAnyMetricValue = ctx.metrics.contains { $0.value != nil }
        let hasAnyNotes = ctx.notes?.contains(where: { !$0.isEmpty }) == true
        guard hasAnyMetricValue || hasAnyNotes else { return nil }

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

        let dateStr = ctx.reportDate ?? "date unknown"

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
            date: ctx.scanDate ?? "date unknown",
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

        let dateStr = report.reportDate ?? "date unknown"

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
        let dateStr = report.scanDate ?? "date unknown"
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

    /// How to read the context, in time: what each block covers and how old
    /// point-in-time reports are. Always the first block.
    static func dataGuide(now: Date = Date(), calendar: Calendar = .current) -> String {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
        let monthStart = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        return """
            \(clockLine(now: now, timeZone: calendar.timeZone))
            How to read the data below, by time:
            - Wearable metrics are daily values from Apple Health. "Latest" values are the most recent completed day \
            (each is labeled with its day); 7-day and 30-day figures run \(LumaDate.day(monthStart, calendar: calendar)) to \
            \(LumaDate.day(yesterday, calendar: calendar)). Today's partial totals are a separate block; use them only for \
            questions about today.
            - Long-term history (monthly and yearly averages) and any period the user names come from the phone's vault.
            - Lab reports (bloodwork, DEXA, gut microbiome, medical documents) are point-in-time snapshots. Each is labeled \
            with its date and age. Quote that age; never estimate how old a report is.
            - A snapshot describes the body on its date. Don't use it to explain the last few weeks unless it was taken in \
            that time. A report older than about 3 months is background: you may bring it in, but say how old it is \
            ("your DEXA from November 2025, 11 months ago") and don't present it as current.
            - When the same kind of report exists from different dates, compare by date and say which is the newest.
            - Keep events in order: something dated after a report (a conversation, a supplement, a habit) can't explain \
            that report's values.
            - Timeline events (medications, illnesses, injuries, procedures, lifestyle changes, notes) are what the user \
            logged, each with its date and age. Line them up with the metrics by date ("since you started creatine on …").
            - If the user asks about a period or report that isn't below, say you don't have it rather than estimating.
            """
    }

    /// Build chat context from the dashboard's cached today data + trends.
    /// Returns nil if no meaningful data is available.
    static func buildCurrentContext() -> AIChatContext? {
        let dashboard = DashboardService.shared
        let today = dashboard.today

        // Nothing loaded yet: return nil and Luma works without metrics. Recent
        // days count even when today has no data yet (early morning, watch off).
        let hasRecentDays = [dashboard.stepsTrend, dashboard.heartRateTrend, dashboard.hrvTrend, dashboard.sleepTrend]
            .contains { !($0[.month] ?? []).isEmpty }
        guard hasRecentDays || today.steps > 0 || today.heartRateAvg > 0 || today.sleepHours > 0 else {
            return nil
        }

        /// A metric's 30-day summary; `latest` is the most recent completed day
        /// (or `todayValue` for readings that are complete once taken), with its day.
        func metric(_ trend: [TrendPeriod: [TrendPoint]], range: Bool = true, todayValue: Double = 0) -> MetricContext? {
            let previous = previousDay(trend)
            let latest: (value: Double, date: Date)? = todayValue > 0 ? (todayValue, Date()) : previous.map { ($0.value, $0.date) }
            guard latest != nil || !(trend[.month] ?? []).isEmpty else { return nil }
            return MetricContext(
                average: monthAverage(trend),
                min: range ? monthMin(trend) : nil,
                max: range ? monthMax(trend) : nil,
                latest: latest?.value,
                sevenDayAvg: weekAverage(trend),
                trend: computeTrend(trend),
                latestDate: latest?.date
            )
        }

        let metrics = AIChatMetrics(
            steps: metric(dashboard.stepsTrend),
            heartRate: metric(dashboard.heartRateTrend),
            hrv: metric(dashboard.hrvTrend),
            // Sleep is last night's completed data once it ends
            sleep: metric(dashboard.sleepTrend, todayValue: today.sleepHours),
            exercise: metric(dashboard.exerciseTrend, range: false),
            // RHR is a resting/morning measurement — today's reading is valid
            restingHeartRate: metric(dashboard.rhrTrend, range: false, todayValue: today.restingHeartRate),
            // VO2 max isn't measured daily: the latest reading is whenever it was
            vo2Max: metric(dashboard.vo2Trend, range: false, todayValue: today.vo2Max),
            respiratoryRate: metric(dashboard.rrTrend, range: false),
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
        blocks.append(ContextBlock(type: "data_note", content: dataGuide()))

        // 2. metrics — formatted health metrics text
        blocks.append(ContextBlock(type: "metrics", content: formatMetrics(metrics, dateRange: dateRange)))

        // 2b. today_partial — running totals for cumulative metrics (steps, calories, exercise)
        //     These match what the dashboard displays and allow Luma to answer "today" questions correctly.
        let todayPartialContent = formatTodayPartial(today)
        if !todayPartialContent.isEmpty {
            blocks.append(ContextBlock(type: "today_partial", content: todayPartialContent))
        }

        // 3. labs_bloodwork, labs_trends, labs_dexa, labs_medical, labs_gut — separate blocks for targeted queries
        blocks += labBlocks()

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
    /// Starts from buildCurrentContext()'s blocks — data_note, metrics, labs —
    /// adds the timeline, and layers in intent-specific extras (hr_zones, workouts, anomalies).
    /// Goals and memory blocks are excluded here since enrichContext() injects them
    /// via the AIChatMemoryCapsule to avoid duplication.
    static func buildContext(for intent: ChatIntent, mode: ChatMode, message: String? = nil,
                             intents: Set<ChatIntent>? = nil) -> AIChatContext? {
        let intents = intents ?? [intent]
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
        // Labs don't depend on today's health metrics: include them even when
        // nothing has loaded yet (early morning, no HealthKit, cold start).
        if full == nil {
            blocks = [ContextBlock(type: "data_note", content: dataGuide())] + labBlocks()
        }

        let periods = message.map { LumaPeriodResolver.resolve($0) } ?? []
        let labs = intents.contains { $0.includesLabData }
        let timeline = intents.contains { $0.includesTimelineEvents }

        // The timeline doesn't depend on metrics either. Every question gets
        // what holds now; the full list goes with deep mode, timeline topics
        // ("since I started…", an illness, a logged item by name) and named periods.
        let events = TimelineService.shared.contextEvents()
        let fullTimeline = mode == .deep || timeline || !periods.isEmpty
            || message.map { ChatIntentClassifier.mentionsTimeline($0, names: timelineNames(events)) } == true
        let timelineContent = formatTimeline(events, summary: !fullTimeline)
        if !timelineContent.isEmpty {
            blocks.append(ContextBlock(type: "timeline", content: timelineContent))
        }

        // In quick mode, prune blocks not relevant to the intents
        if mode == .quick {
            if !labs {
                blocks.removeAll { $0.type == "labs_bloodwork" || $0.type == "labs_dexa" || $0.type == "labs_gut" }
            }
            // Bloodwork history is for lab questions; body-comp questions only need the DEXA.
            if !intents.contains(where: { $0.includesLabData && $0 != .bodyComp }) {
                blocks.removeAll { $0.type == "labs_trends" }
            }
            // Medical documents also carry medications and diagnoses.
            if !labs && !timeline {
                blocks.removeAll { $0.type == "labs_medical" }
            }
            // A period reaching back past the last month may be about an older report, so the index stays.
            let monthAgo = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            if !labs && !timeline && !periods.contains(where: { $0.start < monthAgo }) {
                blocks.removeAll { $0.type == "labs_index" }
            }
        }

        // Layer in intent-specific extras
        if mode == .deep || intents.contains(where: \.includesHRZones) {
            if let hr = buildHRZonesBlock() { blocks.append(hr) }
        }
        if mode == .deep || intents.contains(where: \.includesWorkouts) {
            if let w = buildWorkoutsBlock() { blocks.append(w) }
        }
        if mode == .deep || intents.contains(where: \.includesAnomalies) {
            if let a = buildAnomaliesBlock() { blocks.append(a) }
        }

        // Older data: monthly/yearly history, and any period the user named.
        let keys: Set<String>? = mode == .deep ? nil : historyKeys(for: intents)
        blocks += historyBlocks(periods: periods, keys: keys)

        let metricsToUse: AIChatMetrics?
        if mode == .deep {
            metricsToUse = full?.metrics
        } else {
            let metricKeys = intents.reduce(into: Set<String>()) { $0.formUnion($1.metricKeys) }
            metricsToUse = full?.metrics.flatMap { filterMetrics($0, to: metricKeys) }
        }

        return AIChatContext(
            metrics: metricsToUse ?? full?.metrics,
            dateRange: dateRange,
            contextBlocks: blocks.isEmpty ? nil : blocks
        )
    }

    /// History series for these intents: their metrics, plus body measurements
    /// for body-composition and general questions. Medication questions get none.
    static func historyKeys(for intents: Set<ChatIntent>) -> Set<String> {
        var keys = intents.reduce(into: Set<String>()) { $0.formUnion($1.metricKeys) }
        if intents.contains(.bodyComp) || intents.contains(.general) { keys.insert("body") }
        return keys
    }

    /// The vault's long-term history and the user's named periods, plus any
    /// older report dated within a named period, shown in full.
    static func historyBlocks(periods: [LumaPeriodResolver.Period], keys: Set<String>?, now: Date = Date()) -> [ContextBlock] {
        guard let vault = LocalVault.shared.database else { return [] }
        var blocks: [ContextBlock] = []
        let history = LumaHistoryBuilder(vault: vault, now: now)
        if keys.map({ !$0.isEmpty }) ?? true, let monthly = history.monthlyHistory(keys: keys) {
            blocks.append(ContextBlock(type: "history", content: monthly))
        }
        for period in periods {
            // A named period gets every series: "how was March" isn't about one metric.
            blocks.append(ContextBlock(type: "period", content: history.periodDetail(period, keys: nil)))
        }
        if let labs = LabContextService.shared.currentContext() {
            for period in periods {
                // Reports dated within two weeks of the period count as from it.
                let pad: TimeInterval = 14 * 86_400
                let from = period.start.addingTimeInterval(-pad), to = period.end.addingTimeInterval(pad + 86_399)
                func inPeriod(_ raw: String?) -> Bool {
                    guard let d = LumaDate.parse(raw) else { return false }
                    return d >= from && d <= to
                }
                for bw in labs.olderBloodwork where inPeriod(bw.reportDate) {
                    blocks.append(ContextBlock(type: "labs_period", content: formatBloodwork(bw, latest: false, now: now)))
                }
                for dx in labs.olderDexa where inPeriod(dx.scanDate) {
                    blocks.append(ContextBlock(type: "labs_period", content: formatDexa(dx, latest: false, now: now)))
                }
                for gut in labs.olderGutHealth where inPeriod(gut.date) {
                    if let content = formatGutHealth(gut, now: now) {
                        blocks.append(ContextBlock(type: "labs_period", content: content))
                    }
                }
            }
        }
        // The same report can match two periods.
        var seen = Set<String>()
        return blocks.filter { $0.type != "labs_period" || seen.insert($0.content).inserted }
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
        formatWorkouts(DashboardService.shared.recentWorkoutSummaries).map {
            ContextBlock(type: "workouts", content: $0)
        }
    }

    /// One line per workout with local start/end times, how long ago, and
    /// the recording source, so Luma never has to guess when it happened.
    static func formatWorkouts(_ items: [WorkoutSummaryItem], now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard !items.isEmpty else { return nil }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "EEE d MMM"
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        let lines = ["Recent workouts, last 7 days (local times; only these workouts exist, do not infer others):"]
            + items.prefix(14).map { w in
                var relative = ""
                if calendar.isDate(w.date, inSameDayAs: now) { relative = "today" }
                else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(w.date, inSameDayAs: y) { relative = "yesterday" }
                else { relative = "\(max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: w.date), to: calendar.startOfDay(for: now)).day ?? 0)) days ago" }
                var span = time.string(from: w.date)
                if let end = w.endDate { span += "–" + time.string(from: end) }
                var line = "  \(day.string(from: w.date)) (\(relative)) \(span): \(w.activityType), \(Int(w.durationMinutes.rounded())) min"
                if let source = w.sourceName, !source.isEmpty { line += " [\(source)]" }
                return line
            }
        return lines.joined(separator: "\n")
    }

    /// The user's local clock, so Luma knows the actual time of day.
    static func clockLine(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        let seconds = timeZone.secondsFromGMT(for: now)
        let sign = seconds < 0 ? "-" : "+"
        let offset = String(format: "UTC%@%02d:%02d", sign, abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
        return "User's local time now: \(f.string(from: now)) (\(timeZone.identifier), \(offset))."
    }

    private static func buildAnomaliesBlock() -> ContextBlock? {
        let anomalies = TimelineService.shared.events.filter(\.isAnomaly).prefix(10)
        guard !anomalies.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let lines = ["Recent auto-detected anomalies:"] + anomalies.map { e in
            "  \(formatter.string(from: e.timestamp)) (\(LumaDate.age(of: e.timestamp))): \(e.titleText)\(e.subtitleText.map { " — \($0)" } ?? "")"
        }
        return ContextBlock(type: "anomalies", content: lines.joined(separator: "\n"))
    }

    // MARK: - Block Formatters (used by buildCurrentContext)
    /// "yesterday", "last night", or the day and how long ago ("Sat 17 Oct, 4 days ago").
    static func latestLabel(_ date: Date?, night: Bool = false, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return night ? "last night" : "yesterday" }
        if calendar.isDate(date, inSameDayAs: now) { return night ? "last night" : "today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
            return night ? "night ending yesterday" : "yesterday"
        }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM"
        return "\(f.string(from: date)), \(LumaDate.age(of: date, now: now, calendar: calendar))"
    }

    static func formatMetrics(_ m: AIChatMetrics, dateRange: AIChatDateRange, now: Date = Date()) -> String {
        var parts: [String] = []
        parts.append("Health metrics (latest = most recent completed day, labeled; 7-day avg = last 7 completed days; "
                     + "trend = last 15 days vs the 15 before):")

        func line(_ name: String, _ ctx: MetricContext?, format: String, unit: String, perDay: String = "",
                  night: Bool = false, showTrend: Bool = true) {
            guard let ctx else { return }
            let latest = ctx.latest.map { String(format: format, $0) } ?? "N/A"
            var out = "- \(name): \(latest)\(unit) (\(latestLabel(ctx.latestDate, night: night, now: now)))"
            if let avg = ctx.sevenDayAvg { out += ", 7-day avg " + String(format: format, avg) + unit + perDay }
            if let avg = ctx.average { out += ", 30-day avg " + String(format: format, avg) + unit + perDay }
            if showTrend, let trend = ctx.trend { out += " (trend: \(trend))" }
            parts.append(out)
        }
        line("Steps", m.steps, format: "%.0f", unit: "", perDay: "/day")
        line("Heart Rate", m.heartRate, format: "%.0f", unit: " bpm")
        line("HRV", m.hrv, format: "%.0f", unit: " ms")
        line("Sleep", m.sleep, format: "%.1f", unit: " hrs", perDay: "/night", night: true)
        line("Deep sleep", m.sleepDeepHours, format: "%.1f", unit: " hrs", night: true, showTrend: false)
        line("REM sleep", m.sleepRemHours, format: "%.1f", unit: " hrs", night: true, showTrend: false)
        line("Exercise", m.exercise, format: "%.0f", unit: " mins", perDay: "/day")
        line("Resting Heart Rate", m.restingHeartRate, format: "%.0f", unit: " bpm")
        line("VO2 Max", m.vo2Max, format: "%.1f", unit: " mL/kg/min", showTrend: false)
        line("Respiratory Rate", m.respiratoryRate, format: "%.1f", unit: " breaths/min", showTrend: false)
        if let rs = m.recoveryScore {
            parts.append("- Recovery Score: \(rs)/100 (today)")
        }
        parts.append("Data range: \(dateRange.start) to \(dateRange.end)")
        return parts.joined(separator: "\n")
    }

    /// Size caps for the lab history blocks, in characters.
    static let maxTrendsChars = 5_000
    static let maxMedicalChars = 4_000
    private static let maxMedicalItemChars = 300

    /// The latest bloodwork and DEXA from the vault, earlier values of
    /// repeating markers, and recent medical documents, as context blocks.
    /// Included even when specific values are nil: the structure still helps
    /// and avoids "empty response" failures.
    static func labBlocks(now: Date = Date()) -> [ContextBlock] {
        guard let labs = LabContextService.shared.currentContext() else { return [] }
        var blocks: [ContextBlock] = []
        if let index = formatLabIndex(labs.index, now: now) {
            blocks.append(ContextBlock(type: "labs_index", content: index))
        }
        if let bw = labs.bloodwork {
            blocks.append(ContextBlock(type: "labs_bloodwork", content: formatBloodwork(bw, now: now)))
        }
        if let trends = formatTrends(labs.bloodworkTrends, now: now) {
            blocks.append(ContextBlock(type: "labs_trends", content: trends))
        }
        if let dx = labs.dexa {
            var content = formatDexa(dx, now: now)
            if let history = formatDexaHistory(labs.olderDexa, now: now) { content += "\n" + history }
            blocks.append(ContextBlock(type: "labs_dexa", content: content))
        }
        if let medical = formatMedicalDocuments(labs.medicalDocuments, now: now) {
            blocks.append(ContextBlock(type: "labs_medical", content: medical))
        }
        if let gut = labs.gutHealth, var content = formatGutHealth(gut, now: now) {
            if let history = formatGutHistory(labs.olderGutHealth, now: now) { content += "\n" + history }
            blocks.append(ContextBlock(type: "labs_gut", content: content))
        }
        return blocks
    }

    /// Every report in the vault with its date and age, so Luma knows what
    /// exists, including reports older than the ones shown in full.
    static let maxIndexEntries = 30

    static func formatLabIndex(_ entries: [LabIndexEntry], now: Date = Date()) -> String? {
        guard !entries.isEmpty else { return nil }
        let lines = entries.prefix(maxIndexEntries).map { e -> String in
            var line = "  - \(e.kind): " + LumaDate.reportWhen(e.date, verb: "dated", uploadedAt: e.uploadedAt, now: now)
            if let source = e.source, !source.isEmpty { line += " — \(source)" }
            if e.valueCount > 0 { line += " (\(e.valueCount) value\(e.valueCount == 1 ? "" : "s"))" }
            return line
        }
        var out = "Reports in the user's vault, newest first (\(entries.count) total):\n" + lines.joined(separator: "\n")
        if entries.count > maxIndexEntries { out += "\n  (\(entries.count - maxIndexEntries) older not listed)" }
        return out
    }

    /// Earlier DEXA scans' whole-body values, newest first.
    static func formatDexaHistory(_ scans: [LabDexaContext], now: Date = Date()) -> String? {
        guard !scans.isEmpty else { return nil }
        let lines = scans.map { dx -> String in
            var values: [String] = []
            if let v = dx.bodyFatPercent { values.append("body fat \(v)%") }
            if let v = dx.leanMassKg { values.append("lean mass \(v) kg") }
            if let v = dx.visceralFatRating { values.append("visceral fat \(v)") }
            if let v = dx.androidGynoidRatio { values.append("A/G ratio \(v)") }
            if let v = dx.boneDensityTScore { values.append("T-score \(v)") }
            return "  - " + LumaDate.reportWhen(dx.scanDate, verb: "scanned", uploadedAt: dx.uploadedAt, now: now)
                + ": " + (values.isEmpty ? "no whole-body values" : values.joined(separator: ", "))
        }
        return "Earlier DEXA scans (newest first):\n" + lines.joined(separator: "\n")
    }

    /// Earlier gut reports' summary values, newest first.
    static func formatGutHistory(_ reports: [LabGutHealthContext], now: Date = Date()) -> String? {
        guard !reports.isEmpty else { return nil }
        let lines = reports.map { gut -> String in
            let summary = gut.values.filter { $0.section == "summary" }.map { v -> String in
                var out = v.name.replacingOccurrences(of: "_", with: " ")
                if let n = v.value { out += " " + String(format: "%g", n) }
                else if let t = v.text { out += ": \(t)" }
                return out
            }
            return "  - " + LumaDate.reportWhen(gut.date, verb: "collected", uploadedAt: gut.uploadedAt, now: now)
                + (gut.source.map { " — \($0)" } ?? "") + ": "
                + (summary.isEmpty ? "\(gut.values.count + gut.species.count) values" : summary.joined(separator: "; "))
        }
        return "Earlier gut microbiome reports (newest first):\n" + lines.joined(separator: "\n")
    }

    /// Gut reports carry hundreds of values: summary and flagged values come
    /// first, then each section, then the most abundant species, capped.
    static let maxGutChars = 6_000
    static let gutTopSpecies = 25

    static func formatGutHealth(_ gut: LabGutHealthContext, now: Date = Date()) -> String? {
        guard !gut.values.isEmpty || !gut.species.isEmpty else { return nil }
        func entry(_ v: LabGutHealthContext.Value) -> String {
            var out = v.name.replacingOccurrences(of: "_", with: " ")
            if let n = v.value {
                out += " " + String(format: "%g", n)  // full precision: abundances like 0.005
                if let u = v.unit, !u.isEmpty { out += u == "%" ? "%" : " \(u)" }
            }
            else if let t = v.text { out += ": \(t)" }
            if let s = v.status, !s.isEmpty { out += " (\(s.replacingOccurrences(of: "_", with: " ")))" }
            return out
        }
        let flaggedStatuses: Set<String> = ["needs_support", "needs_improving", "improving"]
        var lines: [String] = []
        let summary = gut.values.filter { $0.section == "summary" }
        if !summary.isEmpty { lines.append("  Summary: " + summary.map(entry).joined(separator: "; ")) }
        let flagged = gut.values.filter { $0.section != "summary" && flaggedStatuses.contains($0.status ?? "") }
        if !flagged.isEmpty { lines.append("  Needs attention: " + flagged.map(entry).joined(separator: "; ")) }
        var order: [String] = []
        var bySection: [String: [LabGutHealthContext.Value]] = [:]
        for v in gut.values where v.section != "summary" {
            if bySection[v.section] == nil { order.append(v.section) }
            bySection[v.section, default: []].append(v)
        }
        if !gut.species.isEmpty {
            var counts: [String: Int] = [:]
            for s in gut.species { counts[s.status ?? "unknown", default: 0] += 1 }
            let breakdown = counts.keys.sorted().map { "\(counts[$0]!) \($0)" }.joined(separator: ", ")
            lines.append("  Species: \(gut.species.count) detected (\(breakdown)). Most abundant: "
                         + gut.species.prefix(gutTopSpecies).map(entry).joined(separator: "; "))
        }
        for section in order {
            let title = section.replacingOccurrences(of: "_", with: " ")
            lines.append("  \(title.prefix(1).uppercased() + title.dropFirst()): "
                         + (bySection[section] ?? []).map(entry).joined(separator: "; "))
        }
        var header = "Gut microbiome report ("
            + LumaDate.reportWhen(gut.date, verb: "collected", uploadedAt: gut.uploadedAt, now: now) + ")"
        if let source = gut.source { header += " — \(source)" }
        return capped(header: header + ":", lines, limit: maxGutChars)
    }

    /// Appends lines up to `limit` characters, then notes how many were left out.
    private static func capped(header: String, _ lines: [String], limit: Int) -> String {
        var out = header
        for (i, line) in lines.enumerated() {
            if out.count + line.count + 1 > limit {
                out += "\n  (\(lines.count - i) more not shown)"
                break
            }
            out += "\n" + line
        }
        return out
    }

    private static func formatTrends(_ trends: [LabMarkerTrend], now: Date = Date()) -> String? {
        guard !trends.isEmpty else { return nil }
        // Ages once per draw date, so each value doesn't repeat them.
        var drawDates: [String] = []
        for t in trends { for p in t.points { if let d = p.date, !drawDates.contains(d) { drawDates.append(d) } } }
        let legend = drawDates
            .sorted { LumaDate.sortDate($0, uploadedAt: nil) > LumaDate.sortDate($1, uploadedAt: nil) }
            .compactMap { LumaDate.stamp($0, now: now) }
            .joined(separator: "; ")
        let lines = trends.map { t in
            "  - \(t.name): " + t.points.map { p in
                "\(LabReportWithMarkers.format(p.value))\(p.unit.map { " \($0)" } ?? "")\(p.date.map { " (\($0))" } ?? "")"
            }.joined(separator: " ← ")
        }
        return capped(header: "Bloodwork history for markers measured more than once (newest first). "
                      + "Draw dates: \(legend).", lines, limit: maxTrendsChars)
    }

    private static func formatMedicalDocuments(_ docs: [LabMedicalDocumentContext], now: Date = Date()) -> String? {
        guard !docs.isEmpty else { return nil }
        func clip(_ text: String) -> String {
            text.count > maxMedicalItemChars ? String(text.prefix(maxMedicalItemChars)) + "…" : text
        }
        var lines: [String] = []
        for doc in docs {
            var header = "  - \(doc.title ?? "Medical document")"
            if let type = doc.documentType, !type.isEmpty { header += " [\(type)]" }
            header += " (" + LumaDate.reportWhen(doc.date, verb: "dated", uploadedAt: doc.uploadedAt, now: now) + ")"
            lines.append(header)
            if let summary = doc.summary, !summary.isEmpty { lines.append("    Summary: " + clip(summary)) }
            if !doc.findings.isEmpty { lines.append("    Findings: " + clip(doc.findings.joined(separator: "; "))) }
            if !doc.diagnoses.isEmpty { lines.append("    Diagnoses: " + clip(doc.diagnoses.joined(separator: "; "))) }
            if !doc.medications.isEmpty { lines.append("    Medications: " + clip(doc.medications.joined(separator: "; "))) }
        }
        return capped(header: "Medical documents (newest first):", lines, limit: maxMedicalChars)
    }

    static func formatBloodwork(_ bw: LabBloodworkContext, latest: Bool = true, now: Date = Date()) -> String {
        var lines: [String] = []
        var header = (latest ? "Latest bloodwork lab results (" : "Bloodwork lab results (")
            + LumaDate.reportWhen(bw.reportDate, verb: "drawn", uploadedAt: bw.uploadedAt, now: now) + ")"
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

    static func formatDexa(_ dx: LabDexaContext, latest: Bool = true, now: Date = Date()) -> String {
        var lines: [String] = []
        let header = (latest ? "Latest DEXA body composition scan (" : "DEXA body composition scan (")
            + LumaDate.reportWhen(dx.scanDate, verb: "scanned", uploadedAt: dx.uploadedAt, now: now) + ")"
        lines.append(header + ":")
        if let v = dx.bodyFatPercent     { lines.append("  • Body fat: \(v)%") }
        if let v = dx.leanMassKg         { lines.append("  • Lean mass: \(v) kg") }
        if let v = dx.visceralFatRating  { lines.append("  • Visceral fat rating: \(v)") }
        if let v = dx.androidGynoidRatio { lines.append("  • Android/Gynoid ratio: \(v)") }
        if let v = dx.boneDensityTScore  { lines.append("  • Bone density T-score: \(v)") }
        if let v = dx.boneDensityZScore  { lines.append("  • Bone density Z-score: \(v)") }
        if !dx.regions.isEmpty {
            lines.append("  Regions:")
            for r in dx.regions {
                let values = r.values.map { v in
                    "\(v.label) \(LabReportWithMarkers.format(v.value))\(v.unit.map { $0 == "%" ? "%" : " \($0)" } ?? "")"
                }
                lines.append("  - \(r.region): " + values.joined(separator: ", "))
            }
        }
        if let notes = dx.notes, !notes.isEmpty {
            lines.append("  Notes: " + notes.joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }

    /// Today's running totals for cumulative metrics — matches what the dashboard shows.
    /// Only includes metrics with a non-zero value to keep the block concise.
    private static func formatTodayPartial(_ today: DashboardTodayData) -> String {
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"
        var lines: [String] = ["Today's running totals since midnight (as of \(time.string(from: Date())) local time):"]
        if today.steps > 0 {
            lines.append(String(format: "  - Steps: %.0f (so far today)", today.steps))
        }
        if today.activeCalories > 0 {
            lines.append(String(format: "  - Active calories: %.0f kcal (so far today)", today.activeCalories))
        }
        if today.exerciseMinutes > 0 {
            lines.append(String(format: "  - Exercise: %.0f min (so far today)", today.exerciseMinutes))
        }
        if today.heartRateAvg > 0 {
            lines.append(String(format: "  - Heart rate avg: %.0f bpm (today)", today.heartRateAvg))
        }
        guard lines.count > 1 else { return "" }
        return lines.joined(separator: "\n")
    }

    static func formatMemory(_ mem: AIChatMemoryCapsule, latestBloodwork: String? = nil) -> String {
        var parts: [String] = ["User memory (from prior conversations; dated where known — older notes may no longer hold):"]
        // The model doesn't reliably compare dates itself, so say which way round they are.
        if let draw = LumaDate.normalizedDay(latestBloodwork) {
            parts.append("Latest bloodwork was drawn \(draw). Anything noted after that date (a supplement, a change, "
                         + "a conversation) can't have affected it and hasn't been tested yet.")
        }
        if !mem.activeGoals.isEmpty     { parts.append("Goals: " + mem.activeGoals.joined(separator: "; ")) }
        if !mem.activeConcerns.isEmpty  { parts.append("Concerns: " + mem.activeConcerns.joined(separator: "; ")) }
        if !mem.medications.isEmpty     { parts.append("Medications/supplements: " + mem.medications.joined(separator: "; ")) }
        if !mem.conditions.isEmpty      { parts.append("Conditions: " + mem.conditions.joined(separator: "; ")) }
        if !mem.preferences.isEmpty     { parts.append("Preferences: " + mem.preferences.joined(separator: "; ")) }
        if !mem.recentSessionNotes.isEmpty {
            parts.append("Recent conversation notes: " + mem.recentSessionNotes.joined(separator: " | "))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Timeline

    /// Upper bound on the timeline block, in characters (~1k tokens).
    static let timelineCharCap = 4_000

    /// The user's health timeline, every entry dated with its day and age:
    /// what holds now (medications and supplements at their latest dose,
    /// open conditions, illnesses and injuries, allergies), anomalies from the
    /// last 30 days, then logged events newest first. `summary` keeps what holds
    /// now and the last 30 days' events, for questions that aren't about the timeline.
    static func formatTimeline(_ events: [TimelineEvent], summary: Bool = false,
                               now: Date = Date(), calendar: Calendar = .current) -> String {
        guard !events.isEmpty else { return "" }
        func when(_ date: Date) -> String {
            "\(LumaDate.day(date, calendar: calendar)), \(LumaDate.age(of: date, now: now, calendar: calendar))"
        }
        let logged = events.filter { !$0.isAnomaly }.sorted { $0.timestamp < $1.timestamp }

        // --- What holds now: replay starts, changes and stops in order ---
        struct Open {
            let name: String
            var dose: String?
            let since: Date
            var notes: [String] = []
        }
        enum Kind: CaseIterable { case medication, supplement, condition, illness, injury, allergy }
        var open: [Kind: [Open]] = [:]
        func same(_ a: String, _ b: String) -> Bool {
            let a = a.lowercased(), b = b.lowercased()
            return a.contains(b) || b.contains(a)
        }
        func start(_ kind: Kind, _ name: String?, _ event: TimelineEvent, dose: String? = nil, notes: [String] = []) {
            guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            open[kind, default: []].removeAll { same($0.name, name) }
            open[kind, default: []].append(Open(name: name, dose: dose, since: event.timestamp, notes: notes))
        }
        func close(_ kinds: [Kind], _ name: String?) {
            guard let name, !name.isEmpty else { return }
            for kind in kinds { open[kind]?.removeAll { same($0.name, name) } }
        }
        for e in logged {
            let d = e.data
            switch e.eventType {
            case .medicationStarted: start(.medication, d["name"], e, dose: d["dosage"])
            case .supplementStarted: start(.supplement, d["name"], e, dose: d["dosage"])
            case .medicationStopped, .supplementStopped: close([.medication, .supplement], d["name"])
            case .medicationDosageChanged:
                guard let name = d["name"], !name.isEmpty else { break }
                let note = "dose changed \(LumaDate.day(e.timestamp, calendar: calendar))"
                if let kind = [Kind.medication, .supplement].first(where: { open[$0]?.contains { same($0.name, name) } ?? false }),
                   let i = open[kind]?.firstIndex(where: { same($0.name, name) }) {
                    open[kind]![i].dose = d["newDosage"] ?? open[kind]![i].dose
                    open[kind]![i].notes.append(note)
                } else {
                    start(.medication, name, e, dose: d["newDosage"], notes: [note])
                }
            case .conditionDiagnosed: start(.condition, d["condition"], e)
            case .conditionResolved: close([.condition], d["condition"])
            case .conditionImproved:
                if let c = d["condition"], let i = open[.condition]?.firstIndex(where: { same($0.name, c) }) {
                    open[.condition]![i].notes.append("improved \(LumaDate.day(e.timestamp, calendar: calendar))")
                }
            case .illnessStarted: start(.illness, d["illness"], e, dose: d["severity"])
            case .illnessResolved: close([.illness], d["illness"])
            case .injuryOccurred: start(.injury, d["injury"], e, dose: d["severity"])
            case .injuryResolved, .injuryHealed: close([.injury], d["injury"])
            case .allergyAdded: start(.allergy, d["allergen"], e, dose: d["severity"].map { "(\($0))" })
            default: break
            }
        }
        let headings: [Kind: (title: String, verb: String)] = [
            .medication: ("Current medications", "since"), .supplement: ("Current supplements", "since"),
            .condition: ("Ongoing conditions", "diagnosed"), .illness: ("Ongoing illnesses", "since"),
            .injury: ("Ongoing injuries", "since"), .allergy: ("Allergies", "logged"),
        ]
        var lines: [String] = []
        for kind in Kind.allCases {
            guard let items = open[kind], !items.isEmpty, let heading = headings[kind] else { continue }
            lines.append("\(heading.title):")
            for item in items.suffix(10) {
                let label = [item.name, item.dose].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
                let notes = item.notes.isEmpty ? "" : "; " + item.notes.joined(separator: "; ")
                lines.append("  • \(label) (\(heading.verb) \(when(item.since))\(notes))")
            }
        }

        // --- Recent anomalies (last 30 days) ---
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let anomalies = events.filter { $0.isAnomaly && $0.timestamp >= monthAgo }.sorted { $0.timestamp > $1.timestamp }
        if !anomalies.isEmpty {
            lines.append("Health anomalies, last 30 days:")
            for e in anomalies.prefix(summary ? 3 : 5) {
                let metric = e.metricType ?? "unknown metric"
                let dir = e.direction.map { " (\($0))" } ?? ""
                let dev = e.deviationPct.map { String(format: " %.0f%% vs baseline", $0) } ?? ""
                lines.append("  • \(when(e.timestamp)): \(metric) anomaly\(dir)\(dev)")
            }
        }

        // --- Logged events, newest first, up to the cap ---
        let newestFirst = logged.reversed().filter { !timelineDetail($0).isEmpty || $0.eventType != .custom }
        let listed = summary ? newestFirst.filter { $0.timestamp >= monthAgo } : Array(newestFirst)
        let header = "User health timeline (events the user logged, each with its date and age):"
        // Room for the header, a section title and the "not listed" line.
        var used = lines.reduce(header.count + 160) { $0 + $1.count + 1 }
        var shown = 0
        var eventLines: [String] = []
        for e in listed.prefix(summary ? 5 : 30) {
            let detail = timelineDetail(e)
            let line = "  • \(when(e.timestamp)): \(timelineLabel(e))\(detail.isEmpty ? "" : " — \(detail)")"
            guard used + line.count + 1 <= timelineCharCap else { break }
            eventLines.append(line)
            used += line.count + 1
            shown += 1
        }
        if !eventLines.isEmpty {
            lines.append(summary ? "Events, last 30 days:" : "Events, newest first:")
            lines += eventLines
        }
        let omitted = newestFirst.count - shown
        if omitted > 0, let oldest = newestFirst.last {
            lines.append("(\(omitted) \(shown > 0 ? "earlier " : "")logged events, back to \(LumaDate.day(oldest.timestamp, calendar: calendar)), aren't listed here.)")
        }

        guard !lines.isEmpty else { return "" }
        lines.insert(header, at: 0)
        return lines.joined(separator: "\n")
    }

    /// The things the user logged by name (medications, conditions, injuries…),
    /// so a question naming one ("since the creatine") reaches the full timeline.
    static func timelineNames(_ events: [TimelineEvent]) -> [String] {
        let keys = ["name", "condition", "injury", "illness", "procedure", "allergen"]
        return Array(Set(events.flatMap { e in keys.compactMap { e.data[$0] } }))
    }

    /// "Injury Occurred", or a custom event's own title.
    private static func timelineLabel(_ e: TimelineEvent) -> String {
        e.eventType == .custom ? e.titleText : e.eventType.displayName
    }

    /// What the user logged for an event, in a line: the thing itself, its
    /// details, then notes, plus any field this app doesn't know.
    static func timelineDetail(_ e: TimelineEvent) -> String {
        var data = e.data.compactMapValues { v -> String? in
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if e.eventType == .custom, e.titleText != e.eventType.displayName {
            data = data.filter { $0.value != e.titleText }
        }
        var parts: [String] = []
        func take(_ key: String) -> String? { data.removeValue(forKey: key) }
        switch e.eventType {
        case .bloodPressureRecorded:
            if let s = take("systolic"), let d = take("diastolic") { parts.append("\(s)/\(d) mmHg") }
        case .weightRecorded:
            if let w = take("weight") { parts.append([w, take("unit")].compactMap { $0 }.joined(separator: " ")) }
        case .medicationDosageChanged:
            if let name = take("name") { parts.append(name) }
            let previous = take("previousDosage"), next = take("newDosage")
            if let next { parts.append(previous.map { "\($0) → \(next)" } ?? "now \(next)") }
        default: break
        }
        let ordered = ["title", "name", "condition", "injury", "illness", "procedure", "allergen", "panel",
                       "change", "event", "height", "dosage", "severity", "symptoms", "reaction", "highlight",
                       "diagnosedBy", "provider", "reason", "duration", "details"]
        parts += ordered.compactMap { take($0) }
        let notes = take("notes")
        parts += data.keys.sorted().map { "\($0): \(data[$0]!)" }
        if let notes { parts.append(notes.count > 160 ? String(notes.prefix(157)) + "…" : notes) }
        return parts.joined(separator: "; ")
    }

    // MARK: - Trend Computation

    /// Compare recent half of 30-day data to prior half.
    /// Returns "rising (+8%)", "stable", or "falling (-6%)". Direction only:
    /// a rising resting heart rate is not an improvement.
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

        if changePct > 5 { return String(format: "rising (+%.0f%%)", changePct) }
        if changePct < -5 { return String(format: "falling (%.0f%%)", changePct) }
        return "stable"
    }

    // MARK: - Helpers

    /// Last complete day's point within 90 days — excludes today's partial
    /// accumulation. Not always yesterday: the watch may not have been worn,
    /// and VO2 max is only measured now and then.
    private static func previousDay(_ trendData: [TrendPeriod: [TrendPoint]]) -> TrendPoint? {
        let today = Calendar.current.startOfDay(for: Date())
        for period in [TrendPeriod.week, .month, .threeMonths] {
            let completed = (trendData[period] ?? []).filter { !Calendar.current.isDate($0.date, inSameDayAs: today) }
            if let last = completed.max(by: { $0.date < $1.date }) { return last }
        }
        return nil
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

        // Latest = the most recent night with stage data (already a completed night)
        let lastNight = data.max { $0.date < $1.date }
        let latest = lastNight?[keyPath: keyPath]

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
            ),
            latestDate: lastNight?.date
        )
    }
}
