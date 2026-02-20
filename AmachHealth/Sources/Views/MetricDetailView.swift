// MetricDetailView.swift
// AmachHealth
//
// Single biomarker deep-dive screen.
// Reached by tapping a MetricCard from Dashboard.
//
// Layout (top → bottom):
//   NavBar           back button + metric name
//   HeroValue        large SF Mono number + unit + status pill
//   RangeBar         visual position within optimal/borderline/critical
//   TimeRangePicker  7D / 30D / 90D / 1Y
//   Chart            line + area (Swift Charts)
//   DataInfo         source badge + last updated
//   LumaSection      "Ask Luma about this" card
//
// State machine: .loading → .loaded(data) / .noData / .error(msg)

import SwiftUI
import Charts

// ============================================================
// MARK: - METRIC INFO (data contract from Dashboard)
// ============================================================

struct MetricInfo: Identifiable, Hashable {
    let id: String
    let icon: String
    let label: String
    let value: String
    let rawValue: Double
    let unit: String
    let color: Color
    let status: HealthStatusPill.Status
    let source: String
    let normalRangeLow: Double    // lower bound of optimal range
    let normalRangeHigh: Double   // upper bound of optimal range
    let absoluteMin: Double       // chart Y-axis min
    let absoluteMax: Double       // chart Y-axis max

    // Normalized position within the full range (0.0–1.0) for RangeBar
    var normalizedPosition: Double {
        guard absoluteMax > absoluteMin else { return 0.5 }
        return max(0, min(1, (rawValue - absoluteMin) / (absoluteMax - absoluteMin)))
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MetricInfo, rhs: MetricInfo) -> Bool { lhs.id == rhs.id }
}

// Default MetricInfo values for common biomarkers
extension MetricInfo {
    static func steps(_ value: Double) -> MetricInfo {
        MetricInfo(id: "steps", icon: "figure.walk", label: "Steps",
                   value: value >= 1000 ? String(format: "%.1fk", value / 1000) : String(Int(value)),
                   rawValue: value, unit: "steps", color: Color.amachPrimaryBright,
                   status: value >= 8000 ? .optimal : value >= 5000 ? .borderline : .critical,
                   source: "Apple Health",
                   normalRangeLow: 8000, normalRangeHigh: 12000,
                   absoluteMin: 0, absoluteMax: 15000)
    }

    static func heartRate(_ bpm: Double) -> MetricInfo {
        MetricInfo(id: "heartRate", icon: "heart.fill", label: "Heart Rate",
                   value: String(Int(bpm)), rawValue: bpm, unit: "bpm",
                   color: Color(hex: "F87171"),
                   status: (bpm >= 60 && bpm <= 80) ? .optimal : (bpm >= 50 && bpm <= 100) ? .borderline : .critical,
                   source: "Apple Watch",
                   normalRangeLow: 60, normalRangeHigh: 80,
                   absoluteMin: 40, absoluteMax: 120)
    }

    static func hrv(_ ms: Double) -> MetricInfo {
        MetricInfo(id: "hrv", icon: "waveform.path.ecg", label: "HRV",
                   value: String(Int(ms)), rawValue: ms, unit: "ms",
                   color: Color.amachPrimaryBright,
                   status: ms >= 50 ? .optimal : ms >= 30 ? .borderline : .critical,
                   source: "Apple Watch",
                   normalRangeLow: 50, normalRangeHigh: 100,
                   absoluteMin: 0, absoluteMax: 150)
    }

    static func sleep(_ hours: Double) -> MetricInfo {
        let formatted = String(format: "%.1f", hours)
        return MetricInfo(id: "sleep", icon: "moon.fill", label: "Sleep",
                   value: formatted, rawValue: hours, unit: "hrs",
                   color: Color(hex: "818CF8"),
                   status: hours >= 7 ? .optimal : hours >= 6 ? .borderline : .critical,
                   source: "Apple Health",
                   normalRangeLow: 7, normalRangeHigh: 9,
                   absoluteMin: 0, absoluteMax: 12)
    }

    static func calories(_ kcal: Double) -> MetricInfo {
        MetricInfo(id: "calories", icon: "flame.fill", label: "Active Cal",
                   value: String(Int(kcal)), rawValue: kcal, unit: "kcal",
                   color: Color.amachAccent,
                   status: kcal >= 400 ? .optimal : kcal >= 200 ? .borderline : .noData,
                   source: "Apple Health",
                   normalRangeLow: 400, normalRangeHigh: 800,
                   absoluteMin: 0, absoluteMax: 1000)
    }

    static func exercise(_ mins: Double) -> MetricInfo {
        MetricInfo(id: "exercise", icon: "figure.run", label: "Exercise",
                   value: String(Int(mins)), rawValue: mins, unit: "min",
                   color: Color.amachAccent,
                   status: mins >= 30 ? .optimal : mins >= 20 ? .borderline : .critical,
                   source: "Apple Health",
                   normalRangeLow: 30, normalRangeHigh: 60,
                   absoluteMin: 0, absoluteMax: 90)
    }
}


// ============================================================
// MARK: - METRIC DETAIL VIEW
// ============================================================

struct MetricDetailView: View {
    let metric: MetricInfo

    @StateObject private var dashboard = DashboardService.shared
    @ObservedObject private var lumaContext = LumaContextService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRange: DetailRange = .week
    @State private var showLuma = false
    @State private var chartDrawProgress: CGFloat = 0
    @State private var selectedDataPoint: TrendPoint? = nil

    enum DetailRange: String, CaseIterable {
        case week = "7D"
        case month = "30D"
        case quarter = "90D"
        case year = "1Y"

        var trendPeriod: TrendPeriod {
            switch self {
            case .week:    return .week
            case .month:   return .month
            case .quarter: return .threeMonths
            case .year:    return .threeMonths // fallback — expand when API supports
            }
        }
    }

    private var trendData: [TrendPoint] {
        let period = selectedRange.trendPeriod
        switch metric.id {
        case "steps":     return dashboard.stepsTrend[period] ?? []
        case "heartRate": return dashboard.heartRateTrend[period] ?? []
        case "hrv":       return dashboard.hrvTrend[period] ?? []
        case "sleep":     return dashboard.sleepTrend[period] ?? []
        default:          return []
        }
    }

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: AmachSpacing.lg) {
                    heroSection
                    rangeBarSection
                    chartSection
                    dataInfoSection
                    lumaSection
                    Spacer().frame(height: AmachSpacing.xxl)
                }
                .padding(.horizontal, AmachSpacing.md)
                .padding(.top, AmachSpacing.md)
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    AmachHaptics.cardTap()
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Back")
                            .font(AmachType.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(Color.amachPrimaryBright)
                }
                .accessibilityLabel("Go back to Dashboard")
            }

            ToolbarItem(placement: .principal) {
                HStack(spacing: AmachSpacing.xs) {
                    Image(systemName: metric.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(metric.color)
                    Text(metric.label)
                        .font(AmachType.h3)
                        .foregroundStyle(Color.amachTextPrimary)
                }
            }
        }
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await dashboard.load()
            lumaContext.update(screen: "Metric Detail", metric: metric.label)
            withAnimation(AmachAnimation.chartDraw) {
                chartDrawProgress = 1
            }
        }
        .onDisappear { lumaContext.update(screen: "Dashboard") }
        .sheet(isPresented: $showLuma) {
            LumaSheetView()
        }
    }

    // MARK: Hero Section

    private var heroSection: some View {
        VStack(spacing: AmachSpacing.md) {
            // Value + unit
            HStack(alignment: .lastTextBaseline, spacing: AmachSpacing.sm) {
                Text(metric.value)
                    .font(AmachType.dataValue(size: 56))
                    .foregroundStyle(Color.amachTextPrimary)
                    .contentTransition(.numericText())
                Text(metric.unit)
                    .font(AmachType.dataUnit(size: 22))
                    .foregroundStyle(Color.amachTextSecondary)
            }
            .frame(maxWidth: .infinity)

            // Status pill + source
            HStack(spacing: AmachSpacing.sm) {
                HealthStatusPill(status: metric.status)
                Spacer()
                SourceBadge(source: metric.source)
            }

            // Status explanation
            statusExplanation
        }
        .padding(AmachSpacing.lg)
        .amachCardElevated()
    }

    private var statusExplanation: some View {
        let (text, color): (String, Color) = {
            switch metric.status {
            case .optimal:
                return ("Your \(metric.label.lowercased()) is in a healthy range.", Color.Amach.Health.optimal)
            case .borderline:
                return ("Your \(metric.label.lowercased()) is slightly outside the typical range. Worth monitoring.", Color.Amach.Health.borderline)
            case .critical:
                return ("Your \(metric.label.lowercased()) is significantly outside the typical range. Consider discussing with your provider.", Color.Amach.Health.critical)
            case .noData:
                return ("No data available for this metric.", Color.amachTextSecondary)
            }
        }()

        return Text(text)
            .font(AmachType.caption)
            .foregroundStyle(color)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Range Bar Section

    private var rangeBarSection: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("RANGE")
                .font(AmachType.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(Color.amachTextSecondary)
                .tracking(1.2)

            VStack(spacing: AmachSpacing.sm) {
                AmachRangeBar(value: metric.normalizedPosition, status: metric.status)

                HStack {
                    Text("\(Int(metric.absoluteMin))")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextTertiary)
                    Spacer()
                    Text("Optimal: \(Int(metric.normalRangeLow))–\(Int(metric.normalRangeHigh)) \(metric.unit)")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                    Spacer()
                    Text("\(Int(metric.absoluteMax))")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextTertiary)
                }
            }
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    // MARK: Chart Section

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            // Time range picker
            HStack {
                Text("HISTORY")
                    .font(AmachType.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.amachTextSecondary)
                    .tracking(1.2)

                Spacer()

                // Range selector
                HStack(spacing: 4) {
                    ForEach(DetailRange.allCases, id: \.self) { range in
                        Button(range.rawValue) {
                            AmachHaptics.toggle()
                            withAnimation(AmachAnimation.spring) { selectedRange = range }
                            chartDrawProgress = 0
                            withAnimation(AmachAnimation.chartDraw.delay(0.05)) {
                                chartDrawProgress = 1
                            }
                        }
                        .font(AmachType.tiny)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            selectedRange == range
                                ? metric.color
                                : Color.amachSurface
                        )
                        .foregroundStyle(
                            selectedRange == range ? .white : Color.amachTextSecondary
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            // Chart
            if trendData.isEmpty {
                noDataChart
            } else {
                metricChart
            }

            // Selected data point detail
            if let point = selectedDataPoint {
                dataPointDetail(point)
            }
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    private var metricChart: some View {
        Chart(trendData) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value(metric.label, point.value)
            )
            .foregroundStyle(metric.color)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2.5))

            AreaMark(
                x: .value("Date", point.date),
                y: .value(metric.label, point.value)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [metric.color.opacity(0.25), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            if let selected = selectedDataPoint, selected.id == point.id {
                PointMark(
                    x: .value("Date", point.date),
                    y: .value(metric.label, point.value)
                )
                .foregroundStyle(metric.color)
                .symbolSize(80)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine()
                    .foregroundStyle(Color.amachPrimary.opacity(0.06))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .font(.system(size: 9))
                    .foregroundStyle(Color.amachTextTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine()
                    .foregroundStyle(Color.amachPrimary.opacity(0.06))
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Color.amachTextTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x - geo.frame(in: .local).minX
                                if let date: Date = proxy.value(atX: x) {
                                    selectedDataPoint = trendData.min { a, b in
                                        abs(a.date.timeIntervalSince(date)) < abs(b.date.timeIntervalSince(date))
                                    }
                                }
                            }
                            .onEnded { _ in
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation(AmachAnimation.fast) { selectedDataPoint = nil }
                                }
                            }
                    )
            }
        }
        .frame(height: 160)
        .animation(AmachAnimation.ifMotion(AmachAnimation.chartDraw), value: trendData.count)
    }

    private var noDataChart: some View {
        VStack(spacing: AmachSpacing.sm) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 32))
                .foregroundStyle(Color.amachTextSecondary.opacity(0.4))
            Text("No data for this period")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
    }

    private func dataPointDetail(_ point: TrendPoint) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(point.date, style: .date)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", point.value))
                        .font(AmachType.dataValue(size: 20))
                        .foregroundStyle(metric.color)
                    Text(metric.unit)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, AmachSpacing.xs)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: Data Info Section

    private var dataInfoSection: some View {
        HStack(spacing: AmachSpacing.md) {
            InfoCell(
                icon: "clock.fill",
                label: "Last Updated",
                value: "Today"
            )
            Divider()
                .frame(height: 32)
                .overlay(Color.amachPrimary.opacity(0.1))
            InfoCell(
                icon: "iphone",
                label: "Source",
                value: metric.source
            )
            Divider()
                .frame(height: 32)
                .overlay(Color.amachPrimary.opacity(0.1))
            InfoCell(
                icon: "chart.bar.fill",
                label: "Data Points",
                value: "\(trendData.count)"
            )
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    // MARK: Luma Section

    private var lumaSection: some View {
        LumaInsightCard(
            insight: lumaInsight,
            onAsk: {
                AmachHaptics.cardTap()
                lumaContext.update(screen: "Metric Detail", metric: metric.label)
                showLuma = true
            }
        )
    }

    private var lumaInsight: String {
        switch metric.id {
        case "steps":
            return "Step count is one of the most studied longevity markers. Each 1,000-step increase is associated with meaningful reductions in all-cause mortality. Context matters — consistency over 7+ days tells a cleaner story than any single day."
        case "heartRate":
            return "Resting heart rate reflects autonomic nervous system balance. A lower RHR generally indicates better cardiovascular efficiency. Short-term spikes from stress, caffeine, or poor sleep are normal — trends over weeks matter more than today's number."
        case "hrv":
            return "HRV is your body's stress and recovery meter. Higher is generally better, but your personal baseline matters more than population averages. Watch for drops after poor sleep, illness, or high training load — those are recovery signals."
        case "sleep":
            return "Sleep is when your body repairs, consolidates memory, and regulates hormones. 7–9 hours is the research-backed target, but sleep quality (stages) matters as much as duration. Check your deep and REM percentages when available."
        default:
            return "I'm tracking \(metric.label) alongside your other metrics to find patterns. Tap to ask me anything about what this data means for you specifically."
        }
    }
}

// MARK: - Supporting Components

private struct SourceBadge: View {
    let source: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "iphone")
                .font(.system(size: 9))
            Text(source)
                .font(AmachType.tiny)
        }
        .foregroundStyle(Color.amachTextSecondary)
        .padding(.horizontal, AmachSpacing.sm)
        .padding(.vertical, 3)
        .background(Color.amachSurface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1))
    }
}

private struct InfoCell: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.amachTextSecondary)
            Text(value)
                .font(AmachType.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.amachTextPrimary)
            Text(label)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MetricDetailView(metric: .heartRate(68))
    }
    .environmentObject(HealthKitService.shared)
    .environmentObject(DashboardService.shared)
    .preferredColorScheme(.dark)
}
