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
    /// - Parameters:
    ///   - sevenDayAvg: 7-day avg of completed days. When provided with dayProgress, enables
    ///     time-of-day-aware pacing status instead of a raw absolute threshold.
    ///   - dayProgress: Fraction of the day elapsed (0.0–1.0). Must be provided alongside sevenDayAvg.
    static func steps(_ value: Double, sevenDayAvg: Double? = nil, dayProgress: Double? = nil) -> MetricInfo {
        let status: HealthStatusPill.Status = Self.cumulativeStatus(
            value: value,
            sevenDayAvg: sevenDayAvg,
            dayProgress: dayProgress,
            absoluteOptimal: 8000,
            absoluteBorderline: 5000
        )
        return MetricInfo(id: "steps", icon: "figure.walk", label: "Steps",
                   value: value >= 1000 ? String(format: "%.1fk", value / 1000) : String(Int(value)),
                   rawValue: value, unit: "steps", color: Color.amachPrimaryBright,
                   status: status,
                   source: "Apple Health",
                   normalRangeLow: 8000, normalRangeHigh: 12000,
                   absoluteMin: 0, absoluteMax: 15000)
    }

    static func heartRate(_ bpm: Double) -> MetricInfo {
        MetricInfo(id: "heartRate", icon: "heart.fill", label: "Heart Rate",
                   value: String(Int(bpm)), rawValue: bpm, unit: "bpm",
                   color: Color(hex: "F87171"),
                   status: (bpm >= 60 && bpm <= 80) ? .optimal : (bpm >= 50 && bpm <= 100) ? .borderline : .belowTrend,
                   source: "Apple Watch",
                   normalRangeLow: 60, normalRangeHigh: 80,
                   absoluteMin: 40, absoluteMax: 120)
    }

    static func hrv(_ ms: Double) -> MetricInfo {
        MetricInfo(id: "hrv", icon: "waveform.path.ecg", label: "HRV",
                   value: String(Int(ms)), rawValue: ms, unit: "ms",
                   color: Color.amachPrimaryBright,
                   status: ms >= 50 ? .optimal : ms >= 30 ? .borderline : .belowTrend,
                   source: "Apple Watch",
                   normalRangeLow: 50, normalRangeHigh: 100,
                   absoluteMin: 0, absoluteMax: 150)
    }

    static func sleep(_ hours: Double) -> MetricInfo {
        let formatted = String(format: "%.1f", hours)
        return MetricInfo(id: "sleep", icon: "moon.fill", label: "Sleep",
                   value: formatted, rawValue: hours, unit: "hrs",
                   color: Color(hex: "818CF8"),
                   status: hours >= 7 ? .optimal : hours >= 6 ? .borderline : .belowTrend,
                   source: "Apple Health",
                   normalRangeLow: 7, normalRangeHigh: 9,
                   absoluteMin: 0, absoluteMax: 12)
    }

    static func calories(_ kcal: Double, sevenDayAvg: Double? = nil, dayProgress: Double? = nil) -> MetricInfo {
        let status: HealthStatusPill.Status = kcal == 0 ? .noData : Self.cumulativeStatus(
            value: kcal,
            sevenDayAvg: sevenDayAvg,
            dayProgress: dayProgress,
            absoluteOptimal: 400,
            absoluteBorderline: 200
        )
        return MetricInfo(id: "calories", icon: "flame.fill", label: "Active Cal",
                   value: String(Int(kcal)), rawValue: kcal, unit: "kcal",
                   color: Color.amachAccent,
                   status: status,
                   source: "Apple Health",
                   normalRangeLow: 400, normalRangeHigh: 800,
                   absoluteMin: 0, absoluteMax: 1000)
    }

    static func exercise(_ mins: Double, sevenDayAvg: Double? = nil, dayProgress: Double? = nil) -> MetricInfo {
        let status: HealthStatusPill.Status = Self.cumulativeStatus(
            value: mins,
            sevenDayAvg: sevenDayAvg,
            dayProgress: dayProgress,
            absoluteOptimal: 30,
            absoluteBorderline: 20
        )
        return MetricInfo(id: "exercise", icon: "figure.run", label: "Exercise",
                   value: String(Int(mins)), rawValue: mins, unit: "min",
                   color: Color.amachAccent,
                   status: status,
                   source: "Apple Health",
                   normalRangeLow: 30, normalRangeHigh: 60,
                   absoluteMin: 0, absoluteMax: 90)
    }

    static func restingHeartRate(_ bpm: Double) -> MetricInfo {
        MetricInfo(id: "restingHeartRate", icon: "heart.text.square.fill", label: "Resting HR",
                   value: bpm > 0 ? String(Int(bpm)) : "—", rawValue: bpm, unit: "bpm",
                   color: Color(hex: "FB7185"),
                   status: bpm == 0 ? .noData : (bpm >= 50 && bpm <= 70) ? .optimal : (bpm >= 40 && bpm <= 90) ? .borderline : .belowTrend,
                   source: "Apple Watch",
                   normalRangeLow: 50, normalRangeHigh: 70,
                   absoluteMin: 30, absoluteMax: 110)
    }

    static func vo2Max(_ value: Double) -> MetricInfo {
        let formatted = value > 0 ? String(format: "%.1f", value) : "—"
        return MetricInfo(id: "vo2Max", icon: "lungs.fill", label: "VO₂ Max",
                   value: formatted, rawValue: value, unit: "mL/kg/min",
                   color: Color(hex: "34D399"),
                   status: value == 0 ? .noData : value >= 45 ? .optimal : value >= 35 ? .borderline : .belowTrend,
                   source: "Apple Watch",
                   normalRangeLow: 45, normalRangeHigh: 60,
                   absoluteMin: 20, absoluteMax: 80)
    }

    static func respiratoryRate(_ bpm: Double) -> MetricInfo {
        MetricInfo(id: "respiratoryRate", icon: "wind", label: "Resp. Rate",
                   value: bpm > 0 ? String(format: "%.1f", bpm) : "—", rawValue: bpm, unit: "br/min",
                   color: Color(hex: "60A5FA"),
                   status: bpm == 0 ? .noData : (bpm >= 12 && bpm <= 18) ? .optimal : (bpm >= 10 && bpm <= 22) ? .borderline : .belowTrend,
                   source: "Apple Watch",
                   normalRangeLow: 12, normalRangeHigh: 18,
                   absoluteMin: 8, absoluteMax: 30)
    }

    // MARK: - Time-aware status for cumulative metrics

    /// Status for metrics that accumulate across a day (steps, calories, exercise).
    /// When a 7-day average and day-progress fraction are available, compares actual
    /// to the expected pace at this point in the day — so 5,000 steps at noon on a
    /// day where you normally hit 10,000 shows "Below Trend" rather than "Critical".
    ///
    /// Falls back to absolute thresholds when trend data isn't available (e.g. period
    /// averages shown in MetricDetailView).
    private static func cumulativeStatus(
        value: Double,
        sevenDayAvg: Double?,
        dayProgress: Double?,
        absoluteOptimal: Double,
        absoluteBorderline: Double
    ) -> HealthStatusPill.Status {
        // Require at least 10% of the day elapsed to avoid noise at midnight/early morning
        if let avg = sevenDayAvg, let progress = dayProgress, progress >= 0.10, avg > 0 {
            let expected = avg * progress
            if value >= expected * 0.90 { return .optimal }
            return .belowTrend
        }
        // Absolute fallback — used in MetricDetailView period views (full-day averages).
        // Never use .borderline for cumulative metrics: if you haven't finished the day
        // it's below trend; if reviewing a period average it's still below trend not "borderline".
        if value >= absoluteOptimal { return .optimal }
        if value >= absoluteBorderline { return .belowTrend }
        return .belowTrend
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
        case "steps":            return dashboard.stepsTrend[period] ?? []
        case "heartRate":        return dashboard.heartRateTrend[period] ?? []
        case "hrv":              return dashboard.hrvTrend[period] ?? []
        case "sleep":            return dashboard.sleepTrend[period] ?? []
        case "restingHeartRate": return dashboard.rhrTrend[period] ?? []
        case "vo2Max":           return dashboard.vo2Trend[period] ?? []
        case "respiratoryRate":  return dashboard.rrTrend[period] ?? []
        case "calories":         return dashboard.calsTrend[period] ?? []
        case "exercise":         return dashboard.exerciseTrend[period] ?? []
        default:                 return []
        }
    }

    // MARK: - Period-average computed properties
    //
    // When a time range is selected, the hero value and status update
    // to reflect the average for that period rather than today's fixed value.

    private var periodAverage: Double {
        guard !trendData.isEmpty else { return metric.rawValue }
        return trendData.map(\.value).reduce(0, +) / Double(trendData.count)
    }

    /// Period label shown beneath the hero value (e.g. "7D avg")
    private var periodLabel: String {
        switch selectedRange {
        case .week:    return "7D avg"
        case .month:   return "30D avg"
        case .quarter: return "90D avg"
        case .year:    return "1Y avg"
        }
    }

    /// Period average formatted like the original metric display
    private var periodDisplayValue: String {
        let avg = periodAverage
        guard avg > 0 else { return "—" }
        switch metric.id {
        case "sleep", "vo2Max", "respiratoryRate":
            return String(format: "%.1f", avg)
        case "steps":
            return avg >= 1000 ? String(format: "%.1fk", avg / 1000) : String(Int(avg))
        default:
            return String(Int(avg))
        }
    }

    /// Status computed from the period average using the metric's normal range
    private var periodStatus: HealthStatusPill.Status {
        let avg = periodAverage
        guard avg > 0 else { return .noData }
        if avg >= metric.normalRangeLow && avg <= metric.normalRangeHigh {
            return .optimal
        }
        let buffer = (metric.normalRangeHigh - metric.normalRangeLow) * 0.5
        if avg >= (metric.normalRangeLow - buffer) && avg <= (metric.normalRangeHigh + buffer) {
            return .borderline
        }
        return .belowTrend
    }

    /// Normalized 0–1 position of the period average within the metric's absolute range
    private var periodNormalizedPosition: Double {
        let avg = periodAverage
        guard metric.absoluteMax > metric.absoluteMin else { return 0.5 }
        return max(0, min(1, (avg - metric.absoluteMin) / (metric.absoluteMax - metric.absoluteMin)))
    }

    /// Dynamic Y-axis domain: min(data)−5 … max(data)+5, clamped to ≥ 0
    private var chartYDomain: ClosedRange<Double> {
        guard !trendData.isEmpty else {
            return metric.absoluteMin...metric.absoluteMax
        }
        let minVal = trendData.map(\.value).min()!
        let maxVal = trendData.map(\.value).max()!
        let lower = max(0, minVal - 5)
        let upper = maxVal + 5
        // Guard against degenerate range (all identical values)
        if lower >= upper { return max(0, lower - 10)...(upper + 10) }
        return lower...upper
    }

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: AmachSpacing.lg) {
                    heroSection
                    rangeBarSection
                    chartSection
                    if metric.id == "sleep" {
                        sleepStagesSection
                    }
                    if metric.id == "exercise" {
                        hrZonesSection
                    }
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
            // Value + unit + period label
            VStack(spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: AmachSpacing.sm) {
                    Text(periodDisplayValue)
                        .font(AmachType.dataValue(size: 56))
                        .foregroundStyle(Color.amachTextPrimary)
                        .contentTransition(.numericText())
                    Text(metric.unit)
                        .font(AmachType.dataUnit(size: 22))
                        .foregroundStyle(Color.amachTextSecondary)
                }
                Text(periodLabel)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            .frame(maxWidth: .infinity)
            .animation(AmachAnimation.spring, value: selectedRange)

            // Status pill + source
            HStack(spacing: AmachSpacing.sm) {
                HealthStatusPill(status: periodStatus)
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
            switch periodStatus {
            case .optimal:
                return ("Your \(metric.label.lowercased()) average is in a healthy range.", Color.Amach.Health.optimal)
            case .borderline:
                return ("Your \(metric.label.lowercased()) average is slightly outside the typical range. Worth monitoring.", Color.Amach.Health.borderline)
            case .belowTrend:
                return ("Your \(metric.label.lowercased()) average is running below your recent trend. Worth keeping an eye on.", Color.Amach.Health.borderline)
            case .critical:
                return ("Your \(metric.label.lowercased()) average is running below your recent trend. Worth keeping an eye on.", Color.Amach.Health.borderline)
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
                AmachRangeBar(value: periodNormalizedPosition, status: periodStatus)

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
            .animation(AmachAnimation.spring, value: selectedRange)
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
        .chartYScale(domain: chartYDomain)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        // minimumDistance: 10 gives the ScrollView time to
                        // claim vertical pan gestures before this fires
                        DragGesture(minimumDistance: 10)
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

    // MARK: Sleep Stages Section

    private var sleepStagesSection: some View {
        let stageTrend = dashboard.sleepStagesTrend[selectedRange.trendPeriod] ?? []
        return VStack(spacing: AmachSpacing.md) {
            if let recovery = dashboard.today.recoveryScore {
                RecoveryScoreCard(breakdown: recovery)
            }
            SleepStagesChart(
                stagesTrend: stageTrend,
                todayEfficiency: dashboard.today.sleepStages.efficiency,
                recoveryScore: dashboard.today.recoveryScore
            )
        }
    }

    // MARK: HR Zones Section

    private var hrZonesSection: some View {
        let zones = dashboard.hrZonesTrend[selectedRange.trendPeriod] ?? HeartRateZoneMinutes()
        return HeartRateZonesChart(zones: zones, periodLabel: selectedRange.rawValue)
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
