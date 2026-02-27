// TrendsPreviews.swift
// AmachHealth

import SwiftUI

#Preview("Trends — All Categories 🟢") {
    TrendsView()
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}

#Preview("Trends — Athlete Data 🟢") {
    TrendsView()
        .withMockEnvironment()
        .task { @MainActor in MockData.athleteUser() }
}

#Preview("Trends — Needs Attention 🔴") {
    TrendsView()
        .withMockEnvironment()
        .task { @MainActor in MockData.needsAttentionUser() }
}

#Preview("Trends — Empty (New User) ⚪") {
    TrendsView()
        .withMockEnvironment()
        .task { @MainActor in MockData.newUser() }
}
