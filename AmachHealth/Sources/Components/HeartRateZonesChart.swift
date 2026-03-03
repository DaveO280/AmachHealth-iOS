// HeartRateZonesChart.swift
// AmachHealth
//
// Donut chart showing time-in-zone distribution for a selected period.
// Uses SectorMark (Swift Charts, iOS 17+).
// Used in MetricDetailView for the Exercise metric.
// Zones are computed from raw HR samples by DashboardService.

import SwiftUI
import Charts

// ============================================================
// MARK: - HR ZONES CHART
// ============================================================

struct HeartRateZonesChart: View {

    let zones: HeartRateZoneMinutes
    var periodLabel: String = "Today"

    // Zone display definitions — ordered Z1→Z5 (chart draws clockwise from top)
    private struct ZoneDef: Identifiable {
        let id: Int
        let name: String
        let description: String
        let color: Color
        let minutes: Double
    }

    private var zoneDefs: [ZoneDef] {
        [
            ZoneDef(id: 1, name: "Recovery",  description: "<60%",   color: Color(hex: "60A5FA"), minutes: zones.zone1),
            ZoneDef(id: 2, name: "Fat Burn",  description: "60–70%", color: Color(hex: "34D399"), minutes: zones.zone2),
            ZoneDef(id: 3, name: "Aerobic",   description: "70–80%", color: Color(hex: "F59E0B"), minutes: zones.zone3),
            ZoneDef(id: 4, name: "Threshold", description: "80–90%", color: Color(hex: "F97316"), minutes: zones.zone4),
            ZoneDef(id: 5, name: "Peak",      description: ">90%",   color: Color(hex: "EF4444"), minutes: zones.zone5),
        ]
    }

    // Only zones with data, used for the chart sectors
    private var activeSectors: [ZoneDef] {
        zoneDefs.filter { $0.minutes > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            headerRow

            if zones.total < 0.5 {
                noDataView
            } else {
                HStack(alignment: .center, spacing: AmachSpacing.lg) {
                    donutChart
                    legendColumn
                    Spacer()
                }
                .padding(.top, AmachSpacing.xs)
            }
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("HEART RATE ZONES")
                .font(AmachType.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(Color.amachTextSecondary)
                .tracking(1.2)
            Spacer()
            Text(periodLabel)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        }
    }

    // MARK: - Donut Chart

    private var donutChart: some View {
        ZStack {
            Chart(activeSectors) { sector in
                SectorMark(
                    angle: .value("Minutes", sector.minutes),
                    innerRadius: .ratio(0.58),
                    angularInset: 1.5
                )
                .foregroundStyle(sector.color)
                .cornerRadius(3)
            }
            .frame(width: 120, height: 120)

            // Center: total minutes
            VStack(spacing: 1) {
                Text("\(Int(zones.total))")
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.amachTextPrimary)
                Text("min")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .frame(width: 120, height: 120)
        .accessibilityLabel("Heart rate zones, \(Int(zones.total)) total minutes tracked")
    }

    // MARK: - Legend Column (Z5 at top → Z1 at bottom)

    private var legendColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(zoneDefs.reversed())) { zone in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(zone.color.opacity(zone.minutes > 0 ? 1 : 0.25))
                        .frame(width: 10, height: 10)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Z\(zone.id) \(zone.name)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(zone.minutes > 0 ? zone.color : Color.amachTextTertiary)
                        Text(zone.description)
                            .font(.system(size: 9))
                            .foregroundStyle(Color.amachTextTertiary)
                    }
                    Spacer()
                    Text(
                        zone.minutes == 0 ? "—" :
                        zone.minutes < 1  ? "<1m" :
                        "\(Int(zone.minutes))m"
                    )
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(zone.minutes > 0 ? zone.color : Color.amachTextTertiary)
                }
            }
        }
    }

    // MARK: - No Data

    private var noDataView: some View {
        Text("No heart rate zone data for this period")
            .font(AmachType.caption)
            .foregroundStyle(Color.amachTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}
