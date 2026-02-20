// AmachHealthApp.swift
// Main entry point — 4-tab navigation + persistent Luma FAB

import SwiftUI

@main
struct AmachHealthApp: App {
    @StateObject private var healthKit = HealthKitService.shared
    @StateObject private var wallet = WalletService.shared
    @StateObject private var syncService = HealthDataSyncService.shared
    @StateObject private var chatService = ChatService.shared
    @StateObject private var dashboard = DashboardService.shared
    @StateObject private var lumaContext = LumaContextService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(healthKit)
                .environmentObject(wallet)
                .environmentObject(syncService)
                .environmentObject(chatService)
                .environmentObject(dashboard)
                .environmentObject(lumaContext)
                .preferredColorScheme(.dark)
                .task {
                    // Silently request HealthKit on first launch if not yet authorized
                    if healthKit.isHealthKitAvailable && !healthKit.isAuthorized {
                        try? await healthKit.requestAuthorization()
                    }
                }
        }
    }
}


// ============================================================
// MARK: - ROOT VIEW
// ============================================================
// Gates on onboarding. Shows ContentView once complete.
// The Luma FAB overlay lives here so it persists across tabs.

struct RootView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @StateObject private var lumaContext = LumaContextService.shared
    @EnvironmentObject private var healthKit: HealthKitService
    @EnvironmentObject private var wallet: WalletService
    @EnvironmentObject private var syncService: HealthDataSyncService
    @EnvironmentObject private var chatService: ChatService
    @EnvironmentObject private var dashboard: DashboardService

    @State private var showLumaSheet = false

    var body: some View {
        ZStack {
            if !onboardingComplete {
                OnboardingView()
                    .environmentObject(healthKit)
                    .environmentObject(wallet)
                    .transition(.opacity)
            } else {
                contentWithFAB
                    .transition(.opacity)
            }
        }
        .animation(AmachAnimation.normal, value: onboardingComplete)
    }

    private var contentWithFAB: some View {
        ZStack(alignment: .bottomTrailing) {
            // Main tab content
            MainTabView()

            // Luma FAB — visible on all tabs, above tab bar
            LumaFABButton(hasUnread: lumaContext.hasUnread) {
                showLumaSheet = true
            }
            .padding(.trailing, AmachSpacing.md)
            // 83 = tab bar + home indicator, 16 = breathing room
            .padding(.bottom, AmachSpacing.tabBarHeight + AmachSpacing.md)
        }
        .sheet(isPresented: $showLumaSheet) {
            LumaSheetView()
                .environmentObject(healthKit)
        }
    }
}


// ============================================================
// MARK: - MAIN TAB VIEW
// ============================================================
// 4 tabs: Dashboard, Trends, Sync, Profile.
// Luma is NOT a tab — she's the FAB above this view.

struct MainTabView: View {
    @EnvironmentObject private var healthKit: HealthKitService
    @EnvironmentObject private var wallet: WalletService
    @EnvironmentObject private var syncService: HealthDataSyncService
    @EnvironmentObject private var chatService: ChatService
    @EnvironmentObject private var dashboard: DashboardService

    var body: some View {
        TabView {
            // Tab 1: Dashboard
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: AmachIcon.dashboard)
                }

            // Tab 2: Trends
            TrendsView()
                .tabItem {
                    Label("Trends", systemImage: "chart.bar.xaxis")
                }

            // Tab 3: Sync & Upload
            HealthSyncView()
                .tabItem {
                    Label("Sync", systemImage: AmachIcon.sync)
                }

            // Tab 4: Profile
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.fill")
                }
        }
        .tint(Color.amachPrimaryBright)
        .onAppear { applyTabBarAppearance() }
    }

    private func applyTabBarAppearance() {
        // Dark, green-tinted tab bar
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor(Color.amachBg)
        tabAppearance.shadowColor = UIColor(Color.amachPrimary.opacity(0.12))

        // Selected item tint
        tabAppearance.stackedLayoutAppearance.selected.iconColor = UIColor(Color.amachPrimaryBright)
        tabAppearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor(Color.amachPrimaryBright)
        ]
        // Unselected
        tabAppearance.stackedLayoutAppearance.normal.iconColor = UIColor(Color.amachTextSecondary)
        tabAppearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(Color.amachTextSecondary)
        ]

        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance

        // Navigation bar styling
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(Color.amachBg)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor(Color.amachTextPrimary)]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor(Color.amachTextPrimary)]
        navAppearance.shadowColor = UIColor(Color.amachPrimary.opacity(0.08))
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
    }
}


// ============================================================
// MARK: - SHARED TYPE ALIASES
// ============================================================
// TierBadge delegates to the design system canonical version.

typealias TierBadge = AmachTierBadge


// ============================================================
// MARK: - PREVIEW
// ============================================================

#Preview("Root — Onboarded") {
    MainTabView()
        .environmentObject(HealthKitService.shared)
        .environmentObject(WalletService.shared)
        .environmentObject(HealthDataSyncService.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(DashboardService.shared)
        .preferredColorScheme(.dark)
}

#Preview("Root — Onboarding") {
    OnboardingView()
        .environmentObject(HealthKitService.shared)
        .environmentObject(WalletService.shared)
        .preferredColorScheme(.dark)
}
