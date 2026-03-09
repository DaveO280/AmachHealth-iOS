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

import Foundation

@MainActor
struct HealthContextBuilder {

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

        return AIChatContext(
            metrics: metrics,
            dateRange: AIChatDateRange(
                start: formatter.string(from: monthAgo),
                end: formatter.string(from: now)
            ),
            dataNote: dataNote,
            labResults: LabContextService.shared.context
        )
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
