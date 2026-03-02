// HealthContextBuilder.swift
// AmachHealth
//
// Builds AIChatContext from DashboardService's cached data.
// No HealthKit queries — uses what's already fetched.

import Foundation

@MainActor
struct HealthContextBuilder {

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
                average: weekAverage(dashboard.stepsTrend),
                min: weekMin(dashboard.stepsTrend),
                max: weekMax(dashboard.stepsTrend),
                latest: today.steps > 0 ? today.steps : nil,
                trend: computeTrend(dashboard.stepsTrend)
            ),
            heartRate: MetricContext(
                average: weekAverage(dashboard.heartRateTrend),
                min: today.heartRateMin > 0 ? today.heartRateMin : nil,
                max: today.heartRateMax > 0 ? today.heartRateMax : nil,
                latest: today.heartRateAvg > 0 ? today.heartRateAvg : nil,
                trend: computeTrend(dashboard.heartRateTrend)
            ),
            hrv: MetricContext(
                average: weekAverage(dashboard.hrvTrend),
                min: weekMin(dashboard.hrvTrend),
                max: weekMax(dashboard.hrvTrend),
                latest: today.hrv > 0 ? today.hrv : nil,
                trend: computeTrend(dashboard.hrvTrend)
            ),
            sleep: MetricContext(
                average: weekAverage(dashboard.sleepTrend),
                min: weekMin(dashboard.sleepTrend),
                max: weekMax(dashboard.sleepTrend),
                latest: today.sleepHours > 0 ? today.sleepHours : nil,
                trend: computeTrend(dashboard.sleepTrend)
            ),
            exercise: MetricContext(
                average: weekAverage(dashboard.calsTrend),
                min: nil,
                max: nil,
                latest: today.exerciseMinutes > 0 ? today.exerciseMinutes : nil,
                trend: computeTrend(dashboard.calsTrend)
            )
        )

        let formatter = ISO8601DateFormatter()
        let now = Date()
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!

        return AIChatContext(
            metrics: metrics,
            dateRange: AIChatDateRange(
                start: formatter.string(from: weekAgo),
                end: formatter.string(from: now)
            )
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

    private static func weekAverage(_ trendData: [TrendPeriod: [TrendPoint]]) -> Double? {
        guard let weekData = trendData[.week], !weekData.isEmpty else { return nil }
        return weekData.map(\.value).reduce(0, +) / Double(weekData.count)
    }

    private static func weekMin(_ trendData: [TrendPeriod: [TrendPoint]]) -> Double? {
        trendData[.week]?.map(\.value).min()
    }

    private static func weekMax(_ trendData: [TrendPeriod: [TrendPoint]]) -> Double? {
        trendData[.week]?.map(\.value).max()
    }
}
