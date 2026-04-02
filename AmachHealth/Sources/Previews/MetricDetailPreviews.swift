// MetricDetailPreviews.swift
// AmachHealth

import SwiftUI

#Preview("Metric Detail — Steps: Optimal 🟢") {
    MetricDetailView(metric: .steps(9243))
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}

#Preview("Metric Detail — Steps: Below Goal 🟡") {
    MetricDetailView(metric: .steps(5800))
        .withMockEnvironment()
        .task { @MainActor in MockData.needsAttentionUser() }
}

#Preview("Metric Detail — Steps: Below trend 🔴") {
    MetricDetailView(metric: .steps(3240))
        .withMockEnvironment()
        .task { @MainActor in MockData.needsAttentionUser() }
}

#Preview("Metric Detail — HRV: Optimal 🟢") {
    MetricDetailView(metric: .hrv(58))
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}

#Preview("Metric Detail — HRV: Athlete 🟢") {
    MetricDetailView(metric: .hrv(78))
        .withMockEnvironment()
        .task { @MainActor in MockData.athleteUser() }
}

#Preview("Metric Detail — HRV: Below trend 🔴") {
    MetricDetailView(metric: .hrv(24))
        .withMockEnvironment()
        .task { @MainActor in MockData.needsAttentionUser() }
}

#Preview("Metric Detail — Heart Rate: Optimal 🟢") {
    MetricDetailView(metric: .heartRate(64))
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}

#Preview("Metric Detail — Heart Rate: Elevated 🟡") {
    MetricDetailView(metric: .heartRate(88))
        .withMockEnvironment()
        .task { @MainActor in MockData.needsAttentionUser() }
}

#Preview("Metric Detail — Sleep: Optimal 🟢") {
    MetricDetailView(metric: .sleep(7.8))
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}

#Preview("Metric Detail — Sleep: Deprived 🔴") {
    MetricDetailView(metric: .sleep(5.2))
        .withMockEnvironment()
        .task { @MainActor in MockData.needsAttentionUser() }
}

#Preview("Metric Detail — Calories: Optimal 🟢") {
    MetricDetailView(metric: .calories(487))
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}

#Preview("Metric Detail — Exercise: Optimal 🟢") {
    MetricDetailView(metric: .exercise(34))
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}
