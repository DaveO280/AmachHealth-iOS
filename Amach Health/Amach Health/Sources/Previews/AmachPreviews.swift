// AmachPreviews.swift
// AmachHealth
//
// Full Xcode Preview catalog — every screen × every meaningful state.
// Named to match the Figma frame structure for 1:1 handoff.
//
// USAGE:
//   Open any of these previews in Xcode's canvas to inspect the state.
//   All previews use MockData.* to configure shared singletons so
//   state is deterministic and side-effect-free.
//
// FRAME NAMING CONVENTION:
//   "<Screen> — <State> [emoji]"
//   🟢 = optimal / healthy   🟡 = borderline / warning
//   🔴 = critical / error    ⚪ = empty / loading / no data

import SwiftUI

// ============================================================
// MARK: - DASHBOARD
// ============================================================

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


// ============================================================
// MARK: - ONBOARDING
// ============================================================

#Preview("Onboarding — Step 0: Welcome") {
    OnboardingView()
        .environmentObject(HealthKitService.shared)
        .environmentObject(WalletService.shared)
        .preferredColorScheme(.dark)
}

// Steps 1–4 are navigated to via tap — preview the coordinator
// at step 0 and swipe/tap through in Canvas to inspect each step.
// For static Figma frames, use the individual step views below.

#Preview("Onboarding — Step 1: Own Your Data") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        OwnYourDataStep(onContinue: {})
            .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — Step 2: Meet Luma") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        MeetLumaStep(onContinue: {})
            .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — Step 3: Health Permission") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        HealthPermissionStep(
            isRequesting: .constant(false),
            permissionDenied: .constant(false),
            onAllow: {},
            onSkip: {}
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — Step 3: Permission Denied 🔴") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        HealthPermissionStep(
            isRequesting: .constant(false),
            permissionDenied: .constant(true),
            onAllow: {},
            onSkip: {}
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — Step 4: Ready 🟢") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        ReadyStep(onGetStarted: {})
            .padding()
    }
    .preferredColorScheme(.dark)
}


// ============================================================
// MARK: - METRIC DETAIL
// ============================================================

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

#Preview("Metric Detail — Steps: Critical 🔴") {
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

#Preview("Metric Detail — HRV: Critical 🔴") {
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


// ============================================================
// MARK: - TRENDS
// ============================================================

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


// ============================================================
// MARK: - CHAT (Full Screen)
// ============================================================

#Preview("Chat — Empty State ⚪") {
    ChatView()
        .withMockEnvironment()
        .task { @MainActor in
            MockData.healthyUser()
            ChatService.shared.currentSession = ChatSession()
        }
}

#Preview("Chat — Active Conversation 🟢") {
    ChatView()
        .withMockEnvironment()
        .task { @MainActor in
            MockData.healthyUser()
            var session = ChatSession()
            session.messages = MockMessages.conversation
            ChatService.shared.currentSession = session
        }
}

#Preview("Chat — Single Q&A 🟢") {
    ChatView()
        .withMockEnvironment()
        .task { @MainActor in
            MockData.healthyUser()
            var session = ChatSession()
            session.messages = MockMessages.singleQuestion
            ChatService.shared.currentSession = session
        }
}

#Preview("Chat — Needs Attention Context 🔴") {
    ChatView()
        .withMockEnvironment()
        .task { @MainActor in
            MockData.needsAttentionUser()
            ChatService.shared.currentSession = ChatSession()
        }
}


// ============================================================
// MARK: - LUMA HALF-SHEET
// ============================================================

#Preview("Luma Sheet — Empty ⚪") {
    Color.amachBg
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            LumaSheetView()
                .withMockEnvironment()
                .task { @MainActor in
                    MockData.healthyUser()
                    ChatService.shared.currentSession = ChatSession()
                }
        }
        .preferredColorScheme(.dark)
}

#Preview("Luma Sheet — Active Conversation 🟢") {
    Color.amachBg
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            LumaSheetView()
                .withMockEnvironment()
                .task { @MainActor in
                    MockData.healthyUser()
                    var session = ChatSession()
                    session.messages = MockMessages.conversation
                    ChatService.shared.currentSession = session
                }
        }
        .preferredColorScheme(.dark)
}


// ============================================================
// MARK: - HEALTH SYNC
// ============================================================

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


// ============================================================
// MARK: - PROFILE
// ============================================================

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


// ============================================================
// MARK: - FULL APP (Root Navigation)
// ============================================================

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
