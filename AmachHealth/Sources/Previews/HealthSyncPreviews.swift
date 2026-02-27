// HealthSyncPreviews.swift
// AmachHealth

import SwiftUI

#Preview("Sync — Ready to Sync 🟢") {
    HealthSyncView()
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}

#Preview("Sync — In Progress 🟡") {
    HealthSyncView()
        .withMockEnvironment()
        .task { @MainActor in MockData.syncingState() }
}

#Preview("Sync — Last Sync Success 🟢") {
    HealthSyncView()
        .withMockEnvironment()
        .task { @MainActor in
            MockData.healthyUser()
            HealthDataSyncService.shared.syncState = .idle
        }
}

#Preview("Sync — Error State 🔴") {
    HealthSyncView()
        .withMockEnvironment()
        .task { @MainActor in MockData.syncError() }
}

#Preview("Sync — No Wallet ⚪") {
    HealthSyncView()
        .withMockEnvironment()
        .task { @MainActor in MockData.noWallet() }
}

#Preview("Sync — No HealthKit ⚪") {
    HealthSyncView()
        .withMockEnvironment()
        .task { @MainActor in MockData.newUser() }
}
