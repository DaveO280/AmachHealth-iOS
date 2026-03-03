// SleepStagesChart.swift
// AmachHealth
//
// Stacked bar chart showing nightly sleep stage breakdown (core/deep/REM/awake)
// and sleep efficiency. Used in MetricDetailView for the sleep metric.

import SwiftUI
import Charts

// ============================================================
// MARK: - SLEEP STAGES CHART
// ============================================================

struct SleepStagesChart: View {

    let stagesTrend: [SleepStageTrendPoint]
    let efficiency: Double?         // last night's efficiency (0.0–1.0)
    let selectedRange: String       // "7D" / "30D" / "90D" for label

    // Flat data model for Swift Charts series stacking
    private struct StageBar: Identifiable {
        let id = UUID()
        let date: Date
        let stage: Stage
        let hours: Double
    }

    enum Stage: String, CaseIterable {
        case deep  = "Deep"
        case rem   = "REM"
        case core  = "Core"
        case awake = "Awake"

        var color: Color {
            switch self {
            case .deep:  return Color(hex: "3730A3")   // dark indigo
            case .rem:   return Color(hex: "6366F1")   // indigo-500
            case .core:  return Color(hex: "A5B4FC")   // indigo-300
            case .awake: return Color(hex: "64748B")   // slate-500
            }
        }
    }

    // Ordered deep → rem → core → awake so deep is bottom of stack
    private var barData: [StageBar] {
        stagesTrend.flatMap { point -> [StageBar] in
            [
                StageBar(date: point.date, stage: .deep,  hours: point.deepHours),
                StageBar(date: point.date, stage: .rem,   hours: point.remHours),
                StageBar(date: point.date, stage: .core,  hours: point.coreHours),
                StageBar(date: point.date, stage: .awake, hours: point.awakeHours),
            ].filter { $0.hours > 0 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            headerRow
            legendRow
            chartBody
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("SLEEP STAGES")
                .font(AmachType.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(Color.amachTextSecondary)
                .tracking(1.2)
            Spacer()
            if let eff = efficiency {
                efficiencyBadge(eff)
            }
        }
    }

    private func efficiencyBadge(_ efficiency: Double) -> some View {
        HStack(spacing: 4) {
            Text("Efficiency")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
            Text(String(format: "%.0f%%", efficiency * 100))
                .font(AmachType.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(efficiencyColor(efficiency))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(efficiencyColor(efficiency).opacity(0.1))
        .clipShape(Capsule())
    }

    private func efficiencyColor(_ eff: Double) -> Color {
        if eff >= 0.85 { return Color.Amach.Health.optimal }
        if eff >= 0.70 { return Color.Amach.Health.borderline }
        return Color.Amach.Health.critical
    }

    // MARK: - Legend

    private var legendRow: some View {
        HStack(spacing: AmachSpacing.md) {
            ForEach(Stage.allCases, id: \.self) { stage in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(stage.color)
                        .frame(width: 10, height: 10)
                    Text(stage.rawValue)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Chart

    @ViewBuilder
    private var chartBody: some View {
        if barData.isEmpty {
            Text("No stage data for this period")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
                .frame(maxWidth: .infinity, minHeight: 140, alignment: .center)
        } else {
            Chart(barData) { item in
                BarMark(
                    x: .value("Date", item.date, unit: .day),
                    y: .value("Hours", item.hours)
                )
                .foregroundStyle(by: .value("Stage", item.stage.rawValue))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale([
                Stage.deep.rawValue:  Stage.deep.color,
                Stage.rem.rawValue:   Stage.rem.color,
                Stage.core.rawValue:  Stage.core.color,
                Stage.awake.rawValue: Stage.awake.color,
            ])
            .chartLegend(.hidden)
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
            .frame(height: 150)
        }
    }
}
