// AppPreviews.swift
// AmachHealth
//
// Full app root navigation previews.

import SwiftUI

#Preview("Full App — Healthy User 🟢") {
    MainTabView()
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}

#Preview("Full App — New User Onboarding ⚪") {
    OnboardingView()
        .environmentObject(HealthKitService.shared)
        .environmentObject(WalletService.shared)
        .preferredColorScheme(.dark)
        .task { @MainActor in MockData.newUser() }
}
