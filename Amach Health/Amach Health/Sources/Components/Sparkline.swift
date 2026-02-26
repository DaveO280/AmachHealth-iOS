// Sparkline.swift
// AmachHealth
//
// Compact inline trend charts for metric cards, list rows, and
// the Trends view summary header.
//
// Components:
//   SparklineChart   — 60×24pt line+area mini chart (metric card use)
//   MiniTrendChart   — 120×44pt chart with trend arrow (detail/list use)
//   TrendArrow       — standalone directional icon with color semantics
//
// Designer's Intent:
//   Health data earns its meaning through change over time.
//   Every metric card should whisper "here's the last 7 days" without
//   demanding the user navigate to a detail screen. The sparkline
//   is that whisper — minimal, scannable, never dominant.
//
// Chart rendering uses Swift Charts. Data is downsampled automatically
// when count > maxPoints to avoid chart performance degradation.

import SwiftUI
import Charts


// ============================================================
// MARK: - TREND DIRECTION
// ============================================================
//
// Derives the trend direction from an ordered value series.
// positiveIsUp: true for metrics where higher = better (HRV, sleep),
//               false for metrics where lower = better (resting HR).

enum TrendDirection {
    case improving, stable, declining

    /// Derive from the first/second half average of a data series.
    static func from(_ values: [Double], positiveIsUp: Bool = true) -> TrendDirection {
        guard values.count >= 4 else { return .stable }
        let half   = values.count / 2
        let first  = values.prefix(half).reduce(0, +) / Double(half)
        let second = values.suffix(half).reduce(0, +) / Double(half)
        let change = (second - first) / max(abs(first), 1)
        if change > 0.04  { return positiveIsUp ? .improving : .declining }
        if change < -0.04 { return positiveIsUp ? .declining : .improving }
        return .stable
    }

    var icon: String {
        switch self {
        case .improving: return "arrow.up.right"
        case .declining: return "arrow.down.right"
        case .stable:    return "minus"
        }
    }

    var color: Color {
        switch self {
        case .improving: return Color.Amach.Semantic.success
        case .declining: return Color.Amach.Semantic.warning
        case .stable:    return Color.amachTextSecondary
        }
    }

    var label: String {
        switch self {
        case .improving: return "Improving"
        case .declining: return "Declining"
        case .stable:    return "Stable"
        }
    }
}


// ============================================================
// MARK: - TREND ARROW
// ============================================================
//
// Standalone directional icon with semantics. Can be used
// independently of a chart in list rows or summary lines.
//
// Usage:
//   TrendArrow(direction: .improving)
//   TrendArrow(direction: .from(weekValues))

struct TrendArrow: View {
    let direction: TrendDirection
    var size: CGFloat = 12

    var body: some View {
        Image(systemName: direction.icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(direction.color)
            .accessibilityLabel("Trend: \(direction.label)")
    }
}


// ============================================================
// MARK: - SPARKLINE CHART
// ============================================================
//
// Ultra-compact line+area chart for metric cards.
// Fixed at the caller's frame size (use .frame() on the parent).
// Default frame suggestion: .frame(height: 28)
//
// data:      ordered Double values, oldest → newest
//            (pass the last 7 values from DashboardService)
// color:     metric.color — tints line, fill, and latest dot
// showDot:   trailing circle marking the most recent value
// lineWidth: 1.5pt for cards, 2pt for slightly larger contexts
//
// Usage:
//   SparklineChart(data: weeklySteps, color: metric.color)
//       .frame(height: 28)

struct SparklineChart: View {
    let data: [Double]
    var color: Color     = Color.amachPrimary
    var showDot: Bool    = true
    var lineWidth: CGFloat = 1.5

    // Downsample if > 30 points to keep chart rendering fast
    private static let maxPoints = 30

    private var points: [Double] {
        guard data.count > Self.maxPoints else { return data }
        let step = Double(data.count) / Double(Self.maxPoints)
        return (0..<Self.maxPoints).map { i in
            data[min(Int(Double(i) * step), data.count - 1)]
        }
    }

    private var indexed: [(idx: Int, val: Double)] {
        points.enumerated().map { (idx: $0.offset, val: $0.element) }
    }

    private var hasEnoughData: Bool {
        data.filter { $0 > 0 }.count >= 2
    }

    private var yDomain: ClosedRange<Double> {
        let nonZero = points.filter { $0 > 0 }
        guard let lo = nonZero.min(), let hi = nonZero.max(), lo != hi else {
            return 0...1
        }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        if hasEnoughData {
            Chart(indexed, id: \.idx) { point in
                LineMark(
                    x: .value("Day", point.idx),
                    y: .value("Value", point.val)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                ))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Day", point.idx),
                    y: .value("Value", point.val)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.18), color.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                if showDot, let last = indexed.last, point.idx == last.idx {
                    PointMark(
                        x: .value("Day", point.idx),
                        y: .value("Value", point.val)
                    )
                    .foregroundStyle(color)
                    .symbolSize(20)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: yDomain)
        } else {
            // No data: flat dashed baseline
            GeometryReader { geo in
                Path { path in
                    let y = geo.size.height / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(
                    color.opacity(0.22),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
            }
        }
    }
}


// ============================================================
// MARK: - MINI TREND CHART
// ============================================================
//
// Slightly larger chart (use .frame(height: 44) or similar) with
// an optional directional arrow indicating the overall trend.
//
// Designed for MetricDetailView summary area and the Trends tab
// category row headers.
//
// points:        [TrendPoint] from DashboardService (date + value)
// positiveIsUp:  semantic for trend arrow coloring
//
// Usage:
//   MiniTrendChart(points: dashboard.weeklyHRV, color: .amachPrimary)
//       .frame(height: 44)

struct MiniTrendChart: View {
    let points: [TrendPoint]
    var color: Color       = Color.amachPrimary
    var positiveIsUp: Bool = true
    var showArrow: Bool    = true
    var lineWidth: CGFloat = 2.0

    private var values: [Double] { points.map(\.value) }

    private var trend: TrendDirection {
        TrendDirection.from(values, positiveIsUp: positiveIsUp)
    }

    private var yDomain: ClosedRange<Double> {
        let nonZero = values.filter { $0 > 0 }
        guard let lo = nonZero.min(), let hi = nonZero.max(), lo != hi else { return 0...1 }
        let pad = (hi - lo) * 0.15
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        HStack(alignment: .center, spacing: AmachSpacing.sm) {
            Chart(points.indices, id: \.self) { i in
                let p = points[i]

                LineMark(
                    x: .value("Day", i),
                    y: .value("Value", p.value)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    lineJoin: .round
                ))
                .interpolationMethod(.catmullRom)

                AreaMark(
                    x: .value("Day", i),
                    y: .value("Value", p.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.20), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: yDomain)

            if showArrow && !points.isEmpty {
                TrendArrow(direction: trend, size: 13)
                    .frame(width: 20)
            }
        }
        .accessibilityLabel("Trend: \(trend.label)")
    }
}


// ============================================================
// MARK: - PREVIEWS
// ============================================================

private let sampleData: [Double] = [
    7200, 7800, 6900, 8100, 7500, 8400, 9100
]

#Preview("Sparkline variants") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.xl) {
            // Card-size sparklines
            HStack(spacing: AmachSpacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    SparklineChart(data: sampleData, color: Color.amachPrimary)
                        .frame(height: 28)
                    Text("Steps ↑")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .amachCard()

                VStack(alignment: .leading, spacing: 4) {
                    SparklineChart(
                        data: [62, 58, 65, 60, 70, 68, 72],
                        color: Color.Amach.Health.optimal
                    )
                    .frame(height: 28)
                    Text("HRV ↑")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .amachCard()
            }

            // No-data state
            SparklineChart(data: [], color: Color.amachPrimary)
                .frame(height: 28)
                .padding()
                .amachCard()

            // Trend arrows standalone
            HStack(spacing: AmachSpacing.lg) {
                TrendArrow(direction: .improving)
                TrendArrow(direction: .stable)
                TrendArrow(direction: .declining)
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
