// LumaSensitivityView.swift
// AmachHealth
//
// Settings screen for tuning Luma's per-metric anomaly detection sensitivity.
// Reached via ProfileView → Luma Intelligence → Alert Sensitivity.
//
// Each metric has its own window of what counts as significant —
// SpO2 reacts in 1 day; step count needs a week. This screen lets
// users pull those dials in either direction without needing to
// understand the underlying statistics.

import SwiftUI

struct LumaSensitivityView: View {
    @ObservedObject private var store = HealthMemoryStore.shared

    // Local state mirrors UserDefaults for instant UI feedback.
    // Written back to store on every change.
    @State private var sensitivities: [String: SensitivityLevel] = [:]

    // Metrics grouped by category — ordered by most actionable first
    private let groups: [(header: String, footer: String, metrics: [MetricRow])] = [
        (
            header: "Recovery & Stress",
            footer: "HRV is the most sensitive early signal — it drops days before you feel sick. Resting heart rate elevation is a reliable secondary confirmation.",
            metrics: [
                MetricRow("heartRateVariabilitySDNN", "HRV",
                          icon: "waveform.path.ecg",     color: Color(hex: "F87171"),
                          detail: "Monitoring: sustained decline",    absoluteNote: nil),
                MetricRow("restingHeartRate",           "Resting Heart Rate",
                          icon: "heart.fill",            color: Color(hex: "F87171"),
                          detail: "Monitoring: sustained elevation", absoluteNote: "> 100 bpm always alerts"),
            ]
        ),
        (
            header: "Sleep",
            footer: "Sleep duration varies naturally — weekends, travel, stress. A 5-day window separates genuine patterns from lifestyle noise.",
            metrics: [
                MetricRow("sleepDuration",   "Sleep Duration",
                          icon: "moon.fill",             color: Color(hex: "818CF8"),
                          detail: "Monitoring: too short or too long", absoluteNote: "< 4 hours always alerts"),
                MetricRow("sleepEfficiency", "Sleep Quality",
                          icon: "moon.stars.fill",       color: Color(hex: "818CF8"),
                          detail: "Monitoring: fragmented sleep",     absoluteNote: "< 70% efficiency always alerts"),
            ]
        ),
        (
            header: "Vital Signs",
            footer: "These are early illness indicators with low natural variability. A single day below 94% SpO2 is always surfaced regardless of sensitivity.",
            metrics: [
                MetricRow("respiratoryRate",  "Respiratory Rate",
                          icon: "lungs.fill",            color: Color(hex: "60A5FA"),
                          detail: "Monitoring: elevated rate",       absoluteNote: "> 20 brpm always alerts"),
                MetricRow("oxygenSaturation", "Blood Oxygen (SpO₂)",
                          icon: "drop.fill",             color: Color(hex: "60A5FA"),
                          detail: "Monitoring: any decline",         absoluteNote: "< 94% always alerts"),
            ]
        ),
        (
            header: "Activity",
            footer: "Activity is the noisiest signal — weekends, rest days, bad weather. A week-long window avoids lifestyle false positives.",
            metrics: [
                MetricRow("stepCount",          "Daily Steps",
                          icon: "figure.walk",           color: Color.amachPrimaryBright,
                          detail: "Monitoring: sustained low activity", absoluteNote: nil),
                MetricRow("activeEnergyBurned", "Active Energy",
                          icon: "flame.fill",            color: Color.amachAccent,
                          detail: "Monitoring: sustained low output",   absoluteNote: nil),
            ]
        ),
    ]

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            List {
                // Sensitivity header callout
                Section {
                    HStack(spacing: AmachSpacing.md) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.amachAI)
                            .frame(width: 28)
                        Text("Luma adjusts its thresholds per metric. Raise sensitivity to catch patterns earlier; lower it to reduce notification frequency.")
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(3)
                    }
                    .padding(.vertical, AmachSpacing.xs)
                    .listRowBackground(Color.amachAI.opacity(0.06))
                }

                // Per-metric groups
                ForEach(groups, id: \.header) { group in
                    Section {
                        ForEach(group.metrics, id: \.metricType) { row in
                            metricRow(row)
                        }
                    } header: {
                        sectionHeader(group.header)
                    } footer: {
                        Text(group.footer)
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextSecondary)
                            .lineSpacing(2)
                    }
                }

                // Clinical thresholds — informational, not adjustable
                Section {
                    VStack(spacing: 0) {
                        thresholdRow("Blood Oxygen",     "< 94% SpO₂",       "drop.fill",       Color(hex: "60A5FA"))
                        Divider().overlay(Color.amachPrimary.opacity(0.08)).padding(.leading, 28)
                        thresholdRow("Resting HR",       "> 100 bpm",         "heart.fill",      Color(hex: "F87171"))
                        Divider().overlay(Color.amachPrimary.opacity(0.08)).padding(.leading, 28)
                        thresholdRow("Respiratory Rate", "> 20 brpm",         "lungs.fill",      Color(hex: "60A5FA"))
                        Divider().overlay(Color.amachPrimary.opacity(0.08)).padding(.leading, 28)
                        thresholdRow("Sleep Duration",   "< 4 h/night",       "moon.fill",       Color(hex: "818CF8"))
                        Divider().overlay(Color.amachPrimary.opacity(0.08)).padding(.leading, 28)
                        thresholdRow("Sleep Quality",    "< 70% efficiency",  "moon.stars.fill", Color(hex: "818CF8"))
                    }
                    .listRowBackground(Color.amachSurface)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                } header: {
                    sectionHeader("Clinical Thresholds")
                } footer: {
                    Text("These limits always trigger an alert regardless of your sensitivity setting or personal baseline — they represent clinically meaningful values.")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                        .lineSpacing(2)
                }

                // Reset all
                Section {
                    Button {
                        resetAll()
                    } label: {
                        HStack {
                            Spacer()
                            Text("Reset All to Default")
                                .font(AmachType.caption)
                                .foregroundStyle(Color.amachTextSecondary)
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.amachSurface)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Alert Sensitivity")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear { loadSensitivities() }
    }

    // MARK: - Metric row

    private func metricRow(_ row: MetricRow) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            // Header: icon + label + optional absolute threshold note
            HStack(spacing: AmachSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(row.color.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: row.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(row.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(AmachType.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.amachTextPrimary)
                    Text(row.detail)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }

                Spacer()

                if let note = row.absoluteNote {
                    Text(note)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.amachTextTertiary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                }
            }

            // Sensitivity picker — segmented, full width
            Picker("Sensitivity for \(row.label)", selection: binding(for: row.metricType)) {
                Text("Less").tag(SensitivityLevel.low)
                Text("Default").tag(SensitivityLevel.medium)
                Text("More").tag(SensitivityLevel.high)
            }
            .pickerStyle(.segmented)
            .tint(Color.amachAI)
        }
        .padding(.vertical, AmachSpacing.xs + 2)
        .listRowBackground(Color.amachSurface)
    }

    // MARK: - Clinical threshold row (informational)

    private func thresholdRow(
        _ label: String,
        _ value: String,
        _ icon: String,
        _ color: Color
    ) -> some View {
        HStack(spacing: AmachSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
            Spacer()
            Text(value)
                .font(AmachType.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(Color.amachTextPrimary)
        }
        .padding(.vertical, AmachSpacing.sm)
    }

    // MARK: - Binding + state management

    private func binding(for metricType: String) -> Binding<SensitivityLevel> {
        Binding(
            get: { sensitivities[metricType] ?? .medium },
            set: { level in
                sensitivities[metricType] = level
                store.setSensitivity(level, for: metricType)
                AmachHaptics.toggle()
            }
        )
    }

    private func loadSensitivities() {
        for key in MetricSensitivityProfile.defaults.keys {
            sensitivities[key] = store.profile(for: key).sensitivityLevel
        }
    }

    private func resetAll() {
        for key in MetricSensitivityProfile.defaults.keys {
            store.resetSensitivity(for: key)
        }
        loadSensitivities()
        AmachHaptics.toggle()
    }

    // MARK: - Shared header style (matches ProfileView)

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AmachType.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(Color.amachTextSecondary)
            .tracking(1)
    }
}

// MARK: - MetricRow data

private struct MetricRow {
    let metricType: String
    let label: String
    let icon: String
    let color: Color
    let detail: String
    let absoluteNote: String?

    init(_ metricType: String, _ label: String,
         icon: String, color: Color,
         detail: String, absoluteNote: String?) {
        self.metricType   = metricType
        self.label        = label
        self.icon         = icon
        self.color        = color
        self.detail       = detail
        self.absoluteNote = absoluteNote
    }
}

// ============================================================
// MARK: - PREVIEW
// ============================================================

#Preview {
    NavigationStack {
        LumaSensitivityView()
    }
    .preferredColorScheme(.dark)
}
