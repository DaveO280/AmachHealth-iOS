// DashboardView.swift
// AmachHealth
//
// Main health dashboard: today's live HealthKit metrics + trend charts

import SwiftUI
import Charts

struct DashboardView: View {
    @StateObject private var dashboard = DashboardService.shared
    @EnvironmentObject private var syncService: HealthDataSyncService
    @EnvironmentObject private var healthKit: HealthKitService

    @State private var selectedPeriod: TrendPeriod = .week

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        headerSection
                        todaySection
                        trendsSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .refreshable { await dashboard.load(force: true) }
            }
            .navigationBarHidden(true)
        }
        .task { await dashboard.load() }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AMACH HEALTH")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.amachPrimaryBright)
                    .tracking(2.5)

                Text(greeting)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.amachTextPrimary)

                if let date = syncService.lastSyncDate {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.amachPrimaryBright)
                            .frame(width: 5, height: 5)
                        Text("Synced \(timeSince(date))")
                            .font(.caption)
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                } else {
                    Text("Not yet synced")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }

            Spacer()

            if let result = syncService.lastSyncResult, let score = result.score {
                healthScoreRing(score: score, tier: result.tier)
            } else {
                emptyScoreRing
            }
        }
    }

    private func healthScoreRing(score: Int, tier: String?) -> some View {
        ZStack {
            Circle()
                .stroke(Color.amachPrimary.opacity(0.12), lineWidth: 5)
                .frame(width: 70, height: 70)

            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(
                    Color.amachPrimaryBright,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 70, height: 70)
                .shadow(color: Color.amachPrimary.opacity(0.5), radius: 6)

            VStack(spacing: 1) {
                Text("\(score)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.amachTextPrimary)
                if let tier, tier != "NONE" {
                    Text(String(tier.prefix(1)).uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tierColor(tier))
                }
            }
        }
    }

    private var emptyScoreRing: some View {
        ZStack {
            Circle()
                .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 5)
                .frame(width: 70, height: 70)
            Image(systemName: "heart.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.amachPrimary.opacity(0.35))
        }
    }

    // MARK: - Today Section

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("Today")

            if dashboard.isLoading && dashboard.today.steps == 0 {
                skeletonGrid
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    MetricCard(
                        icon: "figure.walk",
                        label: "Steps",
                        value: formatSteps(dashboard.today.steps),
                        unit: "",
                        color: Color.amachPrimaryBright
                    )
                    MetricCard(
                        icon: "flame.fill",
                        label: "Active Cal",
                        value: dashboard.today.activeCalories > 0
                            ? String(Int(dashboard.today.activeCalories)) : "—",
                        unit: dashboard.today.activeCalories > 0 ? "kcal" : "",
                        color: Color.amachAccent
                    )
                    MetricCard(
                        icon: "heart.fill",
                        label: "Heart Rate",
                        value: dashboard.today.heartRateAvg > 0
                            ? String(Int(dashboard.today.heartRateAvg)) : "—",
                        unit: dashboard.today.heartRateAvg > 0 ? "bpm" : "",
                        color: Color(hex: "F87171")
                    )
                    MetricCard(
                        icon: "moon.fill",
                        label: "Sleep",
                        value: dashboard.today.sleepHours > 0
                            ? String(format: "%.1f", dashboard.today.sleepHours) : "—",
                        unit: dashboard.today.sleepHours > 0 ? "hrs" : "",
                        color: Color(hex: "818CF8")
                    )
                    MetricCard(
                        icon: "waveform.path.ecg",
                        label: "HRV",
                        value: dashboard.today.hrv > 0
                            ? String(Int(dashboard.today.hrv)) : "—",
                        unit: dashboard.today.hrv > 0 ? "ms" : "",
                        color: Color.amachPrimaryBright
                    )
                    MetricCard(
                        icon: "figure.run",
                        label: "Exercise",
                        value: String(Int(dashboard.today.exerciseMinutes)),
                        unit: "min",
                        color: Color.amachAccent
                    )
                }
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
            spacing: 12
        ) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.amachSurface)
                    .frame(height: 100)
                    .redacted(reason: .placeholder)
                    .shimmering()
            }
        }
    }

    // MARK: - Trends Section

    private var trendsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionLabel("Trends")
                Spacer()
                periodPicker
            }

            trendChart(
                title: "Steps",
                icon: "figure.walk",
                data: dashboard.stepsTrend[selectedPeriod] ?? [],
                color: Color.amachPrimaryBright,
                yLabel: "steps"
            )

            trendChart(
                title: "Heart Rate",
                icon: "heart.fill",
                data: dashboard.heartRateTrend[selectedPeriod] ?? [],
                color: Color(hex: "F87171"),
                yLabel: "bpm"
            )

            trendChart(
                title: "Sleep",
                icon: "moon.fill",
                data: dashboard.sleepTrend[selectedPeriod] ?? [],
                color: Color(hex: "818CF8"),
                yLabel: "hrs"
            )

            trendChart(
                title: "HRV",
                icon: "waveform.path.ecg",
                data: dashboard.hrvTrend[selectedPeriod] ?? [],
                color: Color.amachPrimaryBright,
                yLabel: "ms"
            )
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(TrendPeriod.allCases, id: \.self) { period in
                Button(period.rawValue) {
                    withAnimation(.spring(response: 0.25)) { selectedPeriod = period }
                }
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    selectedPeriod == period
                        ? Color.amachPrimary
                        : Color.amachSurface
                )
                .foregroundStyle(
                    selectedPeriod == period
                        ? Color.white
                        : Color.amachTextSecondary
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func trendChart(
        title: String,
        icon: String,
        data: [TrendPoint],
        color: Color,
        yLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.amachTextPrimary)
                Spacer()
                if let last = data.last {
                    Text("\(formatValue(last.value, label: yLabel))")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }

            if data.isEmpty {
                HStack {
                    Spacer()
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                    Spacer()
                }
                .frame(height: 80)
            } else {
                Chart(data) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(title, point.value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value(title, point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.18), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: xAxisCount)) {
                        AxisGridLine()
                            .foregroundStyle(Color.amachPrimary.opacity(0.06))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: 9))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) {
                        AxisGridLine()
                            .foregroundStyle(Color.amachPrimary.opacity(0.06))
                        AxisValueLabel()
                            .font(.system(size: 9))
                    }
                }
                .frame(height: 90)
            }
        }
        .padding(16)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.amachTextSecondary)
            .tracking(1.5)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func timeSince(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }

    private func formatSteps(_ steps: Double) -> String {
        if steps >= 10_000 { return String(format: "%.1fk", steps / 1000) }
        if steps >= 1000 { return String(format: "%.1fk", steps / 1000) }
        return String(Int(steps))
    }

    private func formatValue(_ value: Double, label: String) -> String {
        switch label {
        case "hrs": return String(format: "%.1f hrs", value)
        case "bpm": return "\(Int(value)) bpm"
        case "ms": return "\(Int(value)) ms"
        default: return String(Int(value))
        }
    }

    private var xAxisCount: Int {
        switch selectedPeriod {
        case .week: return 4
        case .month: return 5
        case .threeMonths: return 4
        }
    }

    private func tierColor(_ tier: String) -> Color {
        switch tier.uppercased() {
        case "GOLD": return Color.amachAccent
        case "SILVER": return Color.amachSilver
        case "BRONZE": return Color.amachBronze
        default: return Color.amachTextSecondary
        }
    }
}

// MARK: - Metric Card

struct MetricCard: View {
    let icon: String
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.amachTextPrimary)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.caption2)
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(color.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Shimmer Effect

extension View {
    func shimmering() -> some View {
        self.opacity(0.6)
    }
}

// MARK: - Preview

#Preview {
    DashboardView()
        .environmentObject(HealthDataSyncService.shared)
        .environmentObject(HealthKitService.shared)
        .preferredColorScheme(.dark)
}
