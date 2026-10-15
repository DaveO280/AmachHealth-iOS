// VaultDashboardReader.swift
// AmachHealth
//
// Builds the dashboard and trend models from daily_metrics. Same shapes and
// rules as DashboardService's HealthKit queries: one point per day with a
// positive value, today included; sleep is attributed to the day it ends.

import Foundation

struct VaultDashboardReader {
    let vault: VaultDatabase
    var now: Date = Date()
    var calendar: Calendar = .current

    private var todayKey: String { now.vaultDay }

    private func startKey(days: Int) -> String {
        (calendar.date(byAdding: .day, value: -days, to: now) ?? now).vaultDay
    }

    private func rows(_ metric: String, days: Int) -> [DailyMetricRow] {
        (try? vault.dailyMetrics(metric: metric, from: startKey(days: days), through: todayKey)) ?? []
    }

    private func todayRow(_ metric: String) -> DailyMetricRow? {
        try? vault.dailyMetric(metric: metric, day: todayKey)
    }

    // MARK: - Trends

    func trend(_ metric: String, days: Int) -> [TrendPoint] {
        rows(metric, days: days).compactMap { row in
            guard let date = VaultDay.date(row.day), let value = row.primaryValue, value > 0 else { return nil }
            return TrendPoint(date: date, value: value)
        }
    }

    func allPeriods(_ metric: String) -> [TrendPeriod: [TrendPoint]] {
        Dictionary(uniqueKeysWithValues: TrendPeriod.allCases.map { ($0, trend(metric, days: $0.days)) })
    }

    func sleepTrend(days: Int) -> [TrendPoint] {
        rows(AmachMetric.sleepId, days: days).compactMap { row in
            guard let date = VaultDay.date(row.day), let minutes = row.total, minutes > 0 else { return nil }
            return TrendPoint(date: date, value: min(minutes / 60, 16))
        }
    }

    func sleepStagesTrend(days: Int) -> [SleepStageTrendPoint] {
        rows(AmachMetric.sleepId, days: days).compactMap { row in
            guard let date = VaultDay.date(row.day) else { return nil }
            let core = (row.sleepCoreMin ?? 0) / 60, deep = (row.sleepDeepMin ?? 0) / 60
            let rem = (row.sleepRemMin ?? 0) / 60, awake = (row.sleepAwakeMin ?? 0) / 60
            guard core + deep + rem > 0 else { return nil }
            return SleepStageTrendPoint(date: date, coreHours: core, deepHours: deep, remHours: rem, awakeHours: awake)
        }
    }

    // MARK: - Today

    func today() -> DashboardTodayData {
        let hr = todayRow("heart_rate")
        let sleep = todayRow(AmachMetric.sleepId)
        var stages = SleepStageBreakdown()
        stages.coreMinutes = Int(sleep?.sleepCoreMin ?? 0)
        stages.deepMinutes = Int(sleep?.sleepDeepMin ?? 0)
        stages.remMinutes = Int(sleep?.sleepRemMin ?? 0)
        stages.awakeMinutes = Int(sleep?.sleepAwakeMin ?? 0)
        stages.efficiency = sleep?.sleepEfficiency

        return DashboardTodayData(
            steps: todayRow("steps")?.total ?? 0,
            activeCalories: todayRow("active_energy")?.total ?? 0,
            exerciseMinutes: todayRow("exercise_minutes")?.total ?? 0,
            heartRateAvg: hr?.avg ?? 0,
            heartRateMin: hr?.min ?? 0,
            heartRateMax: hr?.max ?? 0,
            hrv: todayRow("hrv_sdnn")?.avg ?? 0,
            restingHeartRate: todayRow("resting_heart_rate")?.avg ?? 0,
            sleepHours: (sleep?.total ?? 0) / 60,
            sleepEfficiency: sleep?.sleepEfficiency,
            sleepStages: stages,
            respiratoryRate: todayRow("respiratory_rate")?.avg ?? 0,
            vo2Max: todayRow("vo2_max")?.avg ?? 0
        )
    }
}
