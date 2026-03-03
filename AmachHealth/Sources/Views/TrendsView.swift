// TrendsView.swift
// AmachHealth
//
// Tab 2: Health history and pattern view.
// Shows all metric trends organised by category with a global period picker.
// Sub-charts (sleep stages, HR zone distribution) appear directly below
// their parent metric card so context is never lost.
//
// Design goal: "Read the signals." Curious optimisers who want to understand
// patterns across time — not just today's snapshot.

import SwiftUI
import Charts

// ============================================================
// MARK: - CATEGORY ENUM
// ============================================================

enum HealthCategory: String, CaseIterable {
    case all            = "All"
    case cardiovascular = "Heart"
    case sleep          = "Sleep"
    case activity       = "Activity"
    case bodyComp       = "Body"

    var icon: String {
        switch self {
        case .all:            return "square.grid.2x2.fill"
        case .cardiovascular: return "heart.fill"
        case .sleep:          return "moon.fill"
        case .activity:       return "figure.walk"
        case .bodyComp:       return "lungs.fill"
        }
    }

    var color: Color {
        switch self {
        case .all:            return Color.amachPrimaryBright
        case .cardiovascular: return Color(hex: "F87171")
        case .sleep:          return Color(hex: "818CF8")
        case .activity:       return Color.amachAccent
        case .bodyComp:       return Color(hex: "34D399")
        }
    }
}


// ============================================================
// MARK: - TRENDS VIEW
// ============================================================

struct TrendsView: View {
    @StateObject private var dashboard = DashboardService.shared
    @ObservedObject private var lumaContext = LumaContextService.shared

    @State private var selectedCategory: HealthCategory = .all
    @State private var selectedPeriod: TrendPeriod = .month
    @State private var showLuma = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: AmachSpacing.lg) {
                        categoryPicker
                        periodPicker
                        chartsSection
                        lumaPatternSection
                        Spacer().frame(height: AmachSpacing.xxxl)
                    }
                    .padding(.horizontal, AmachSpacing.md)
                    .padding(.top, AmachSpacing.sm)
                }
                .refreshable { await dashboard.load(force: true) }
            }
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if dashboard.isLoading {
                        ProgressView()
                            .tint(Color.amachPrimaryBright)
                            .scaleEffect(0.8)
                    }
                }
            }
            .task {
                await dashboard.load()
                lumaContext.update(screen: "Trends")
            }
            .sheet(isPresented: $showLuma) {
                LumaSheetView()
            }
        }
    }

    // MARK: Category Picker

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AmachSpacing.sm) {
                ForEach(HealthCategory.allCases, id: \.self) { cat in
                    Button {
                        AmachHaptics.toggle()
                        withAnimation(AmachAnimation.spring) { selectedCategory = cat }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: cat.icon)
                                .font(.system(size: 11))
                            Text(cat.rawValue)
                                .font(AmachType.tiny)
                                .fontWeight(.semibold)
                        }
                        .padding(.horizontal, AmachSpacing.sm + 4)
                        .padding(.vertical, AmachSpacing.sm)
                        .background(selectedCategory == cat ? cat.color : Color.amachSurface)
                        .foregroundStyle(selectedCategory == cat ? Color.white : Color.amachTextSecondary)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(
                                selectedCategory == cat
                                    ? cat.color.opacity(0.3)
                                    : Color.amachPrimary.opacity(0.1),
                                lineWidth: 1
                            )
                        )
                        .shadow(color: selectedCategory == cat ? cat.color.opacity(0.3) : .clear, radius: 6)
                    }
                    .accessibilityAddTraits(selectedCategory == cat ? .isSelected : [])
                }
            }
            .padding(.horizontal, AmachSpacing.md)
            .padding(.vertical, AmachSpacing.xs)
        }
        .padding(.horizontal, -AmachSpacing.md)
    }

    // MARK: Period Picker

    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(TrendPeriod.allCases, id: \.self) { period in
                Button(period.rawValue) {
                    AmachHaptics.toggle()
                    withAnimation(AmachAnimation.spring) { selectedPeriod = period }
                }
                .font(AmachType.tiny)
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selectedPeriod == period ? Color.amachPrimary : Color.amachSurface)
                .foregroundStyle(selectedPeriod == period ? .white : Color.amachTextSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityAddTraits(selectedPeriod == period ? .isSelected : [])
            }
            Spacer()
        }
    }

    // MARK: Charts Section

    @ViewBuilder
    private var chartsSection: some View {
        let metrics = visibleMetrics
        if metrics.isEmpty {
            emptyState
        } else {
            VStack(spacing: AmachSpacing.md) {
                ForEach(metrics) { config in
                    // Primary trend chart
                    TrendChartCard(config: config, period: selectedPeriod)

                    // Sleep stages appear directly below the Sleep card
                    if config.id == "sleep" {
                        SleepStagesChart(
                            stagesTrend: dashboard.sleepStagesTrend[selectedPeriod] ?? [],
                            todayEfficiency: dashboard.today.sleepStages.efficiency,
                            recoveryScore: dashboard.today.recoveryScore
                        )
                    }

                    // HR zone distribution appears directly below the Exercise card
                    if config.id == "exercise" {
                        HeartRateZonesChart(
                            zones: dashboard.hrZonesTrend[selectedPeriod] ?? HeartRateZoneMinutes(),
                            periodLabel: selectedPeriod.rawValue
                        )
                    }
                }
            }
        }
    }

    // MARK: Metric Configs

    struct TrendMetricConfig: Identifiable {
        let id: String
        let title: String
        let icon: String
        let data: [TrendPoint]
        let color: Color
        let unit: String
        let category: HealthCategory
        var decimalPlaces: Int = 0
    }

    private var allMetrics: [TrendMetricConfig] {
        [
            TrendMetricConfig(
                id: "heartRate", title: "Heart Rate", icon: "heart.fill",
                data: dashboard.heartRateTrend[selectedPeriod] ?? [],
                color: Color(hex: "F87171"), unit: "bpm", category: .cardiovascular),
            TrendMetricConfig(
                id: "restingHeartRate", title: "Resting HR", icon: "heart.text.square.fill",
                data: dashboard.rhrTrend[selectedPeriod] ?? [],
                color: Color(hex: "FB7185"), unit: "bpm", category: .cardiovascular),
            TrendMetricConfig(
                id: "hrv", title: "HRV", icon: "waveform.path.ecg",
                data: dashboard.hrvTrend[selectedPeriod] ?? [],
                color: Color.amachPrimaryBright, unit: "ms", category: .cardiovascular),
            TrendMetricConfig(
                id: "sleep", title: "Sleep", icon: "moon.fill",
                data: dashboard.sleepTrend[selectedPeriod] ?? [],
                color: Color(hex: "818CF8"), unit: "hrs", category: .sleep, decimalPlaces: 1),
            TrendMetricConfig(
                id: "steps", title: "Steps", icon: "figure.walk",
                data: dashboard.stepsTrend[selectedPeriod] ?? [],
                color: Color.amachPrimaryBright, unit: "steps", category: .activity),
            TrendMetricConfig(
                id: "exercise", title: "Exercise", icon: "figure.run",
                data: dashboard.exerciseTrend[selectedPeriod] ?? [],
                color: Color.amachAccent, unit: "min", category: .activity),
            TrendMetricConfig(
                id: "calories", title: "Active Cal", icon: "flame.fill",
                data: dashboard.calsTrend[selectedPeriod] ?? [],
                color: Color.amachAccent, unit: "kcal", category: .activity),
            TrendMetricConfig(
                id: "vo2Max", title: "VO₂ Max", icon: "lungs.fill",
                data: dashboard.vo2Trend[selectedPeriod] ?? [],
                color: Color(hex: "34D399"), unit: "mL/kg/min", category: .bodyComp, decimalPlaces: 1),
            TrendMetricConfig(
                id: "respiratoryRate", title: "Resp. Rate", icon: "wind",
                data: dashboard.rrTrend[selectedPeriod] ?? [],
                color: Color(hex: "60A5FA"), unit: "br/min", category: .bodyComp, decimalPlaces: 1),
        ]
    }

    private var visibleMetrics: [TrendMetricConfig] {
        switch selectedCategory {
        case .all:            return allMetrics
        case .cardiovascular: return allMetrics.filter { $0.category == .cardiovascular }
        case .sleep:          return allMetrics.filter { $0.category == .sleep }
        case .activity:       return allMetrics.filter { $0.category == .activity }
        case .bodyComp:       return allMetrics.filter { $0.category == .bodyComp }
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: AmachSpacing.md) {
            Image(systemName: selectedCategory.icon)
                .font(.system(size: 36))
                .foregroundStyle(selectedCategory.color.opacity(0.4))
            Text("No \(selectedCategory.rawValue) data yet")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)
            Text("Connect Apple Health and sync your data to see trends here.")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(AmachSpacing.xxl)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AmachRadius.card)
                .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: Luma Pattern Section

    private var lumaPatternSection: some View {
        LumaInsightCard(
            insight: patternInsight,
            onAsk: {
                AmachHaptics.cardTap()
                lumaContext.update(screen: "Trends")
                showLuma = true
            }
        )
    }

    private var patternInsight: String {
        switch selectedCategory {
        case .cardiovascular:
            return "Your heart rate and HRV often move inversely — when one rises, the other typically falls. Watch for sustained HRV drops over 3+ days, which often predict recovery needs before you feel them."
        case .sleep:
            return "Sleep quality compounds. Three consecutive nights under 7 hours creates a measurable cognitive and metabolic debt that can take longer than one good night to recover from."
        case .activity:
            return "Step consistency matters more than peak days. A steady 7,000–8,000 steps daily has stronger health associations than irregular high-step days followed by sedentary ones."
        case .bodyComp:
            return "VO₂ Max is one of the strongest predictors of longevity — each 1 MET improvement reduces all-cause mortality risk by ~10–15%. Respiratory rate trends can also flag early illness or under-recovery before you feel it."
        default:
            return "Looking at your data across the selected period, I can spot patterns that single-day views miss — recovery cycles, stress responses, sleep-activity correlations. Ask me what you're curious about."
        }
    }
}


// ============================================================
// MARK: - TREND CHART CARD
// ============================================================
// Full-width chart card: header, dynamic line chart, min/avg/max stats.
// DragGesture uses minimumDistance: 10 so ScrollView keeps vertical scroll.

struct TrendChartCard: View {
    let config: TrendsView.TrendMetricConfig
    let period: TrendPeriod

    @State private var selectedPoint: TrendPoint? = nil

    private var data: [TrendPoint] { config.data }
    private var color: Color { config.color }

    private var stats: (min: Double, max: Double, avg: Double)? {
        guard !data.isEmpty else { return nil }
        let vals = data.map(\.value)
        return (vals.min() ?? 0, vals.max() ?? 0, vals.reduce(0, +) / Double(vals.count))
    }

    /// Dynamic Y-axis: min(data) − 5 … max(data) + 5, never below 0
    private var chartYDomain: ClosedRange<Double> {
        guard !data.isEmpty else { return 0...100 }
        let minVal = data.map(\.value).min()!
        let maxVal = data.map(\.value).max()!
        let lower = max(0, minVal - 5)
        let upper = maxVal + 5
        if lower >= upper { return max(0, lower - 10)...(upper + 10) }
        return lower...upper
    }

    /// Format a value for display using this metric's precision rules
    private func fmt(_ v: Double) -> String {
        if config.id == "steps" {
            return v >= 1000 ? String(format: "%.0fk", v / 1000) : String(Int(v))
        }
        return config.decimalPlaces > 0 ? String(format: "%.1f", v) : String(Int(v))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            // Header: icon + name + latest value
            HStack(spacing: AmachSpacing.sm) {
                Image(systemName: config.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(config.title)
                    .font(AmachType.h3)
                    .foregroundStyle(Color.amachTextPrimary)

                Spacer()

                if let last = data.last {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(fmt(last.value))
                            .font(AmachType.dataValue(size: 18))
                            .foregroundStyle(Color.amachTextPrimary)
                            .contentTransition(.numericText())
                        Text(config.unit)
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                }
            }

            // Chart or no-data placeholder
            if data.isEmpty {
                noDataPlaceholder
            } else {
                chartBody
            }

            // Stats row
            if let s = stats {
                HStack(spacing: 0) {
                    statCell(label: "MIN", value: fmt(s.min))
                    Spacer()
                    Divider().frame(height: 24).overlay(Color.amachPrimary.opacity(0.1))
                    Spacer()
                    statCell(label: "AVG", value: fmt(s.avg))
                    Spacer()
                    Divider().frame(height: 24).overlay(Color.amachPrimary.opacity(0.1))
                    Spacer()
                    statCell(label: "MAX", value: fmt(s.max))
                }
            }
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    // MARK: Chart

    private var chartBody: some View {
        Chart(data) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value(config.title, point.value)
            )
            .foregroundStyle(color)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2))

            AreaMark(
                x: .value("Date", point.date),
                y: .value(config.title, point.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [color.opacity(0.20), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            if let sel = selectedPoint, sel.id == point.id {
                PointMark(
                    x: .value("Date", point.date),
                    y: .value(config.title, point.value)
                )
                .foregroundStyle(color)
                .symbolSize(60)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: xAxisCount)) {
                AxisGridLine().foregroundStyle(Color.amachPrimary.opacity(0.05))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 9))
                    .foregroundStyle(Color.amachTextTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(Color.amachPrimary.opacity(0.05))
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Color.amachTextTertiary)
            }
        }
        .chartYScale(domain: chartYDomain)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(
                        // minimumDistance: 10 — lets ScrollView claim vertical pans first
                        DragGesture(minimumDistance: 10)
                            .onChanged { val in
                                let x = val.location.x - geo.frame(in: .local).minX
                                if let date: Date = proxy.value(atX: x) {
                                    selectedPoint = data.min {
                                        abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                    }
                                }
                            }
                            .onEnded { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation(AmachAnimation.fast) { selectedPoint = nil }
                                }
                            }
                    )
            }
        }
        .frame(height: 120)
    }

    // MARK: Helpers

    private var noDataPlaceholder: some View {
        HStack {
            Spacer()
            VStack(spacing: AmachSpacing.xs) {
                Image(systemName: "chart.line.flattrend.xyaxis")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.amachTextSecondary.opacity(0.3))
                Text("No data")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            Spacer()
        }
        .frame(height: 100)
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
                .tracking(0.8)
            Text(value)
                .font(AmachType.dataValue(size: 15))
                .foregroundStyle(Color.amachTextPrimary)
        }
    }

    private var xAxisCount: Int {
        switch period {
        case .week:        return 4
        case .month:       return 5
        case .threeMonths: return 4
        }
    }
}


// ============================================================
// MARK: - PREVIEW
// ============================================================

#Preview {
    TrendsView()
        .environmentObject(HealthKitService.shared)
        .preferredColorScheme(.dark)
}
