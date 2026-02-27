// ProfilePreviews.swift
// AmachHealth

import SwiftUI

#Preview("Profile — Gold User 🟢") {
    ProfileView()
        .withMockEnvironment()
        .task { @MainActor in MockData.healthyUser() }
}

#Preview("Profile — Silver (Athlete) 🟢") {
    ProfileView()
        .withMockEnvironment()
        .task { @MainActor in MockData.athleteUser() }
}

#Preview("Profile — No Wallet ⚪") {
    ProfileView()
        .withMockEnvironment()
        .task { @MainActor in MockData.noWallet() }
}

#Preview("Profile — New User ⚪") {
    ProfileView()
        .withMockEnvironment()
        .task { @MainActor in MockData.newUser() }
}
