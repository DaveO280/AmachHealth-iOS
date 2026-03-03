// HeartRateZonesChart.swift
// AmachHealth
//
// Horizontal zone bar chart showing today's time-in-zone distribution.
// Used in MetricDetailView for the Heart Rate metric.
// Zones are computed from raw HR samples by DashboardService.fetchTodayHRZones().

import SwiftUI

// ============================================================
// MARK: - HR ZONES CHART
// ============================================================

struct HeartRateZonesChart: View {

    let zones: HeartRateZoneMinutes

    // Zone display definitions — ordered 5→1 (highest effort at top)
    private struct ZoneDef {
        let number: Int
        let name: String
        let description: String
        let color: Color
    }

    private let zoneDefs: [ZoneDef] = [
        ZoneDef(number: 5, name: "Peak",      description: ">90%",    color: Color(hex: "EF4444")),
        ZoneDef(number: 4, name: "Threshold", description: "80–90%",  color: Color(hex: "F97316")),
        ZoneDef(number: 3, name: "Aerobic",   description: "70–80%",  color: Color(hex: "F59E0B")),
        ZoneDef(number: 2, name: "Fat Burn",  description: "60–70%",  color: Color(hex: "34D399")),
        ZoneDef(number: 1, name: "Recovery",  description: "<60%",    color: Color(hex: "60A5FA")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            headerRow

            if zones.total < 0.5 {
                noDataView
            } else {
                VStack(spacing: 6) {
                    ForEach(zoneDefs, id: \.number) { zone in
                        zoneRow(zone)
                    }
                }

                totalRow
            }
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack {
            Text("HEART RATE ZONES")
                .font(AmachType.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(Color.amachTextSecondary)
                .tracking(1.2)
            Spacer()
            Text("Today")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        }
    }

    private func zoneRow(_ zone: ZoneDef) -> some View {
        let mins = zones.minutes(for: zone.number)
        let frac = zones.fraction(for: zone.number)

        return HStack(spacing: AmachSpacing.sm) {
            // Zone label
            VStack(alignment: .leading, spacing: 1) {
                Text("Z\(zone.number) \(zone.name)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(zone.color)
                Text(zone.description)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.amachTextTertiary)
            }
            .frame(width: 74, alignment: .leading)

            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(zone.color.opacity(0.10))
                        .frame(height: 14)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(zone.color.opacity(0.80))
                        .frame(width: max(4, geo.size.width * frac), height: 14)
                }
            }
            .frame(height: 14)

            // Minutes
            Text(mins < 1 ? "<1m" : "\(Int(mins))m")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(mins > 0 ? zone.color : Color.amachTextTertiary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var totalRow: some View {
        HStack {
            Spacer()
            Text("Total tracked: \(Int(zones.total)) min")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .padding(.top, 2)
    }

    private var noDataView: some View {
        Text("No heart rate data recorded today")
            .font(AmachType.caption)
            .foregroundStyle(Color.amachTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
    }
}
