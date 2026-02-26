// PreviewHelpers.swift
// AmachHealth
//
// Preview infrastructure: mock data generators and service configurators.
//
// USAGE IN PREVIEWS:
//   #Preview("Dashboard — Healthy User") {
//       DashboardView()
//           .withMockEnvironment()
//           .task { @MainActor in MockData.healthyUser() }
//   }
//
// Each MockData.* function configures all singletons for that scenario.
// All functions are @MainActor — safe to call from .task { @MainActor in }.

import SwiftUI

// ============================================================
// MARK: - ENVIRONMENT SHORTCUT
// ============================================================
// Apply to any view to inject all required environment objects.

extension View {
    func withMockEnvironment() -> some View {
        self
            .environmentObject(HealthKitService.shared)
            .environmentObject(WalletService.shared)
            .environmentObject(HealthDataSyncService.shared)
            .environmentObject(DashboardService.shared)
            .environmentObject(ChatService.shared)
            .environmentObject(LumaContextService.shared)
            .preferredColorScheme(.dark)
    }
}


// ============================================================
// MARK: - MOCK DATA GENERATORS
// ============================================================

enum MockData {

    // ──────────────────────────────────────────────────────────
    // MARK: Trend Point Generator
    // Creates deterministic, realistic-looking health trend data.
    // Uses sin waves + linear drift — looks natural, not random.
    //
    //   base     — center value (e.g. 8000 steps)
    //   variance — peak-to-peak swing (e.g. 1500 steps)
    //   drift    — total change across the period (+/- = improving/declining)
    // ──────────────────────────────────────────────────────────
    static func trend(
        days: Int,
        base: Double,
        variance: Double,
        drift: Double = 0
    ) -> [TrendPoint] {
        let cal = Calendar.current
        return (0..<days).compactMap { i in
            guard let date = cal.date(
                byAdding: .day,
                value: -(days - 1 - i),
                to: Date()
            ) else { return nil }

            let phase = Double(i)
            // Two overlapping sin waves for natural feel
            let noise = sin(phase * 0.9) * variance * 0.6
                      + sin(phase * 2.3 + 1.1) * variance * 0.4
            let linearDrift = drift * (Double(i) / Double(max(days - 1, 1)))
            let value = max(0, base + noise + linearDrift)
            return TrendPoint(date: date, value: value)
        }
    }

    // Trend data for all three periods
    static func allPeriods(
        base: Double,
        variance: Double,
        drift: Double = 0
    ) -> [TrendPeriod: [TrendPoint]] {
        [
            .week:        trend(days: 7,  base: base, variance: variance, drift: drift),
            .month:       trend(days: 30, base: base, variance: variance, drift: drift),
            .threeMonths: trend(days: 90, base: base, variance: variance, drift: drift),
        ]
    }


    // ──────────────────────────────────────────────────────────
    // MARK: - SCENARIO 1: Healthy User
    // Gold tier, well-recovered, steady metrics.
    // Luma insight: all green, positive framing.
    // ──────────────────────────────────────────────────────────
    @MainActor
    static func healthyUser() {
        // HealthKit
        HealthKitService.shared.isAuthorized = true

        // Dashboard
        let d = DashboardService.shared
        d.today = DashboardTodayData(
            steps: 9243,
            activeCalories: 487,
            exerciseMinutes: 34,
            heartRateAvg: 64,
            heartRateMin: 52,
            heartRateMax: 118,
            hrv: 58,
            restingHeartRate: 56,
            sleepHours: 7.8,
            sleepEfficiency: 0.87,
            respiratoryRate: 14.2,
            vo2Max: 42.1
        )
        d.stepsTrend     = allPeriods(base: 8800,  variance: 1400, drift: 400)
        d.heartRateTrend = allPeriods(base: 65,    variance: 4,    drift: -2)
        d.hrvTrend       = allPeriods(base: 56,    variance: 8,    drift: 6)
        d.sleepTrend     = allPeriods(base: 7.7,   variance: 0.6,  drift: 0.2)
        d.calsTrend      = allPeriods(base: 460,   variance: 80,   drift: 0)
        d.isLoading = false

        // Sync
        let s = HealthDataSyncService.shared
        s.lastSyncResult = SyncResult(
            success: true, storjUri: "storj://amach/abc123",
            contentHash: "0x4f2e8a1b", tier: "GOLD", score: 87,
            metricsCount: 31, daysCovered: 90, error: nil
        )
        s.lastSyncDate = Date().addingTimeInterval(-1800)

        // Wallet
        let w = WalletService.shared
        w.isConnected = true
        w.address = "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
    }


    // ──────────────────────────────────────────────────────────
    // MARK: - SCENARIO 2: Athlete User
    // Silver tier (fewer days synced), elite metrics.
    // Luma insight: strong recovery, high VO2.
    // ──────────────────────────────────────────────────────────
    @MainActor
    static func athleteUser() {
        HealthKitService.shared.isAuthorized = true

        let d = DashboardService.shared
        d.today = DashboardTodayData(
            steps: 14_830,
            activeCalories: 720,
            exerciseMinutes: 58,
            heartRateAvg: 57,
            heartRateMin: 44,
            heartRateMax: 162,
            hrv: 78,
            restingHeartRate: 48,
            sleepHours: 8.3,
            sleepEfficiency: 0.91,
            respiratoryRate: 13.1,
            vo2Max: 55.4
        )
        d.stepsTrend     = allPeriods(base: 13_500, variance: 2200, drift: 1000)
        d.heartRateTrend = allPeriods(base: 58,     variance: 5,    drift: -3)
        d.hrvTrend       = allPeriods(base: 72,     variance: 12,   drift: 8)
        d.sleepTrend     = allPeriods(base: 8.1,    variance: 0.5,  drift: 0.3)
        d.calsTrend      = allPeriods(base: 680,    variance: 120,  drift: 0)
        d.isLoading = false

        let s = HealthDataSyncService.shared
        s.lastSyncResult = SyncResult(
            success: true, storjUri: nil, contentHash: nil,
            tier: "SILVER", score: 72, metricsCount: 28,
            daysCovered: 35, error: nil
        )
        s.lastSyncDate = Date().addingTimeInterval(-900)

        let w = WalletService.shared
        w.isConnected = true
        w.address = "0x8Ba1f109551bD432803012645Ac136ddd64DBA72"
    }


    // ──────────────────────────────────────────────────────────
    // MARK: - SCENARIO 3: Needs Attention
    // Borderline/critical metrics. Sleep deprived, low HRV.
    // Luma insight: recovery focus, caution.
    // ──────────────────────────────────────────────────────────
    @MainActor
    static func needsAttentionUser() {
        HealthKitService.shared.isAuthorized = true

        let d = DashboardService.shared
        d.today = DashboardTodayData(
            steps: 3_240,
            activeCalories: 180,
            exerciseMinutes: 0,
            heartRateAvg: 88,
            heartRateMin: 61,
            heartRateMax: 134,
            hrv: 24,
            restingHeartRate: 74,
            sleepHours: 5.2,
            sleepEfficiency: 0.71,
            respiratoryRate: 17.4,
            vo2Max: 0
        )
        d.stepsTrend     = allPeriods(base: 5200,  variance: 1800, drift: -1500)
        d.heartRateTrend = allPeriods(base: 82,    variance: 6,    drift: 8)
        d.hrvTrend       = allPeriods(base: 32,    variance: 6,    drift: -12)
        d.sleepTrend     = allPeriods(base: 6.0,   variance: 0.8,  drift: -1.2)
        d.calsTrend      = allPeriods(base: 220,   variance: 60,   drift: -80)
        d.isLoading = false

        let s = HealthDataSyncService.shared
        s.lastSyncResult = SyncResult(
            success: true, storjUri: nil, contentHash: nil,
            tier: "BRONZE", score: 52, metricsCount: 18,
            daysCovered: 14, error: nil
        )
        s.lastSyncDate = Date().addingTimeInterval(-7200)

        let w = WalletService.shared
        w.isConnected = true
        w.address = "0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF"
    }


    // ──────────────────────────────────────────────────────────
    // MARK: - SCENARIO 4: New User (Empty State)
    // No HealthKit auth. No sync. No data.
    // Luma is waiting to help.
    // ──────────────────────────────────────────────────────────
    @MainActor
    static func newUser() {
        HealthKitService.shared.isAuthorized = false

        let d = DashboardService.shared
        d.today = DashboardTodayData()  // All zeros
        d.stepsTrend = [:]
        d.heartRateTrend = [:]
        d.hrvTrend = [:]
        d.sleepTrend = [:]
        d.calsTrend = [:]
        d.isLoading = false

        let s = HealthDataSyncService.shared
        s.lastSyncResult = nil
        s.lastSyncDate = nil

        let w = WalletService.shared
        w.isConnected = false
        w.address = nil
    }


    // ──────────────────────────────────────────────────────────
    // MARK: - SCENARIO 5: Loading
    // Skeleton state — data is fetching.
    // ──────────────────────────────────────────────────────────
    @MainActor
    static func loadingState() {
        HealthKitService.shared.isAuthorized = true

        let d = DashboardService.shared
        d.today = DashboardTodayData()
        d.isLoading = true
        d.stepsTrend = [:]

        HealthDataSyncService.shared.lastSyncResult = nil
    }


    // ──────────────────────────────────────────────────────────
    // MARK: - SCENARIO 6: Syncing In Progress
    // Shows the sync progress bar, 60% done.
    // ──────────────────────────────────────────────────────────
    @MainActor
    static func syncingState() {
        HealthKitService.shared.isAuthorized = true
        let w = WalletService.shared
        w.isConnected = true
        w.address = "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
        HealthDataSyncService.shared.syncState = .syncing(
            progress: 0.62,
            message: "Encrypting health data…"
        )
    }


    // ──────────────────────────────────────────────────────────
    // MARK: - SCENARIO 7: Sync Error
    // ──────────────────────────────────────────────────────────
    @MainActor
    static func syncError() {
        HealthKitService.shared.isAuthorized = true
        let w = WalletService.shared
        w.isConnected = true
        w.address = "0x71C7656EC7ab88b098defB751B7401B5f6d8976F"
        HealthDataSyncService.shared.lastSyncResult = SyncResult(
            success: false, storjUri: nil, contentHash: nil,
            tier: nil, score: nil, metricsCount: nil, daysCovered: nil,
            error: "Upload failed: connection timed out. Your data is safe — tap Retry."
        )
    }


    // ──────────────────────────────────────────────────────────
    // MARK: - SCENARIO 8: Wallet Not Connected
    // HealthKit authorized but no wallet yet.
    // ──────────────────────────────────────────────────────────
    @MainActor
    static func noWallet() {
        HealthKitService.shared.isAuthorized = true

        let d = DashboardService.shared
        d.today = DashboardTodayData(
            steps: 6_100, activeCalories: 320, exerciseMinutes: 22,
            heartRateAvg: 71, heartRateMin: 58, heartRateMax: 112,
            hrv: 44, restingHeartRate: 62, sleepHours: 7.1,
            sleepEfficiency: 0.82, respiratoryRate: 15.0, vo2Max: 0
        )
        d.stepsTrend     = allPeriods(base: 6500,  variance: 1200, drift: 0)
        d.heartRateTrend = allPeriods(base: 72,    variance: 5,    drift: 0)
        d.hrvTrend       = allPeriods(base: 43,    variance: 7,    drift: 0)
        d.sleepTrend     = allPeriods(base: 7.0,   variance: 0.7,  drift: 0)
        d.calsTrend      = allPeriods(base: 340,   variance: 70,   drift: 0)
        d.isLoading = false

        HealthDataSyncService.shared.lastSyncResult = nil
        HealthDataSyncService.shared.lastSyncDate = nil
        WalletService.shared.isConnected = false
        WalletService.shared.address = nil
    }
}


// ============================================================
// MARK: - MOCK MESSAGES FOR CHAT PREVIEW
// ============================================================

enum MockMessages {
    static var conversation: [ChatMessage] {
        [
            ChatMessage(role: .user,      content: "How's my heart health looking?"),
            ChatMessage(role: .assistant, content: "Your resting heart rate has been averaging 64 bpm over the past week — that's in a healthy range. What stands out more is your HRV: 58ms is above average for your age, which suggests good autonomic balance and recovery capacity.\n\nThe slight downward trend in RHR over the past month is actually a good sign — it typically reflects improving cardiovascular efficiency, possibly from your consistent activity."),
            ChatMessage(role: .user,      content: "What about my sleep? I've been feeling tired"),
            ChatMessage(role: .assistant, content: "Your sleep data tells an interesting story. You're averaging 7.8 hours, which is solid — but your efficiency has dipped to 82% this week (down from 88% last month). That means more time awake or in light sleep.\n\nThe timing matters too: your HRV drops tend to follow the nights where you went to bed after midnight. Even small shifts in sleep timing can affect the deep sleep you get in the first half of the night.\n\nWorth noting: this is a correlation in your data, not a diagnosis. But it's a pattern worth experimenting with."),
            ChatMessage(role: .user,      content: "That makes sense. Anything I should focus on this week?"),
            ChatMessage(role: .assistant, content: "Given what I see, I'd focus on one thing: sleep consistency over sleep duration.\n\nYour body seems to respond well to a stable sleep window — your best HRV readings follow your most consistent nights. Duration varies less than you might think; the 10:30pm–6:30am nights show measurably better next-day HRV than the 12am–8am nights, even with similar total hours.\n\nEverything else in your data looks genuinely good. Steps are consistent, your heart rate trends are moving in the right direction. Don't add more variables — protect the consistency you have."),
        ]
    }

    static var singleQuestion: [ChatMessage] {
        [
            ChatMessage(role: .user,      content: "What should I focus on this week?"),
            ChatMessage(role: .assistant, content: "Looking at your data from the past 7 days, the clearest signal is HRV recovery. Your numbers dipped mid-week — down to 31ms from your 58ms baseline — which often tracks with cumulative stress or under-recovery.\n\nThis week I'd suggest: protect sleep timing over duration, keep exercise intensity moderate until HRV stabilizes, and stay well hydrated. Your steps and heart rate look fine — no concerns there."),
        ]
    }
}
