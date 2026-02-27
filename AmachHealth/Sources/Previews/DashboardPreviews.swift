// DashboardPreviews.swift
// AmachHealth

import SwiftUI

#Preview("Dashboard — Healthy User 🟢") {
    NavigationStack {
        DashboardView()
    }
    .withMockEnvironment()
    .task { @MainActor in MockData.healthyUser() }
}

#Preview("Dashboard — Athlete 🟢") {
    NavigationStack {
        DashboardView()
    }
    .withMockEnvironment()
    .task { @MainActor in MockData.athleteUser() }
}

#Preview("Dashboard — Needs Attention 🔴") {
    NavigationStack {
        DashboardView()
    }
    .withMockEnvironment()
    .task { @MainActor in MockData.needsAttentionUser() }
}

#Preview("Dashboard — New User ⚪") {
    NavigationStack {
        DashboardView()
    }
    .withMockEnvironment()
    .task { @MainActor in MockData.newUser() }
}

#Preview("Dashboard — Loading ⚪") {
    NavigationStack {
        DashboardView()
    }
    .withMockEnvironment()
    .task { @MainActor in MockData.loadingState() }
}

#Preview("Dashboard — No Wallet 🟡") {
    NavigationStack {
        DashboardView()
    }
    .withMockEnvironment()
    .task { @MainActor in MockData.noWallet() }
}
