// AppState.swift
// AmachHealth
//
// Global application state using the @Observable macro (iOS 17+).
// Single source of truth for auth, connected sources, tier, and
// app-level UI state (selected tab, active toast).
//
// Designer's Intent:
//   Health data context flows down from AppState to every screen.
//   No screen should independently track whether the wallet is
//   connected or what tier the user holds — it reads from here.
//
// Setup (AmachHealthApp.swift):
//   @State private var appState = AppState()
//   WindowGroup { RootView().environment(appState) }
//
// Usage in any view:
//   @Environment(AppState.self) private var appState

import SwiftUI


// ============================================================
// MARK: - APP STATE
// ============================================================

@Observable
final class AppState {

    // ── Auth ──────────────────────────────────────────────────

    /// True when wallet is connected and session is valid.
    var isAuthenticated: Bool = false

    /// The connected wallet address (Privy embedded wallet).
    var walletAddress: String? = nil

    // ── User Profile & Tier ───────────────────────────────────

    /// Data quality tier: "GOLD" | "SILVER" | "BRONZE" | "NONE"
    /// Updated after every successful sync.
    var currentTier: String = "NONE"

    /// Completeness score 0–100. Drives the health score ring.
    var dataScore: Int = 0

    /// Timestamp of the last successful HealthKit → Storj sync.
    var lastSyncDate: Date? = nil

    // ── Connected Sources ─────────────────────────────────────

    /// True when HealthKit authorization has been granted.
    var isHealthKitAuthorized: Bool = false

    /// True when Privy wallet is connected and encryption key derived.
    var isWalletConnected: Bool = false

    // ── Navigation ────────────────────────────────────────────

    /// Currently selected bottom tab index (0 = Dashboard).
    var selectedTab: Int = 0

    // ── Onboarding ────────────────────────────────────────────

    /// Persisted across app restarts via UserDefaults.
    var onboardingComplete: Bool {
        get { _onboardingComplete }
        set {
            _onboardingComplete = newValue
            UserDefaults.standard.set(newValue, forKey: "amach.onboardingComplete")
        }
    }
    private var _onboardingComplete: Bool =
        UserDefaults.standard.bool(forKey: "amach.onboardingComplete")

    // ── App-Level Toast ───────────────────────────────────────

    /// Set any AmachToast value to trigger the root-level toast overlay.
    /// Cleared automatically by AmachToastModifier after display.
    var currentToast: AmachToast? = nil

    // ── Computed ──────────────────────────────────────────────

    /// True only when both HealthKit and wallet are ready for sync.
    var isFullyConnected: Bool {
        isHealthKitAuthorized && isWalletConnected
    }

    var tierDisplayName: String {
        switch currentTier.uppercased() {
        case "GOLD":   return "Gold"
        case "SILVER": return "Silver"
        case "BRONZE": return "Bronze"
        default:       return "No Tier"
        }
    }

    /// Returns the amber/silver/bronze/gray tier color for UI use.
    var tierColor: Color {
        switch currentTier.uppercased() {
        case "GOLD":   return Color.amachAccent
        case "SILVER": return Color.amachSilver
        case "BRONZE": return Color.amachBronze
        default:       return Color.amachTextSecondary
        }
    }

    // ── Sync with Existing Services ───────────────────────────

    /// Call after each successful sync to update tier + score + date.
    func recordSync(tier: String, score: Int, date: Date = .now) {
        currentTier = tier
        dataScore   = score
        lastSyncDate = date
    }

    /// Call when the Privy wallet connects or disconnects.
    func setWallet(address: String?) {
        walletAddress     = address
        isWalletConnected = address != nil
        isAuthenticated   = address != nil
    }

    /// Call after HealthKit authorization resolves (success or denial).
    func setHealthKit(authorized: Bool) {
        isHealthKitAuthorized = authorized
    }

    /// Convenience: fire a toast from any service or view.
    func toast(_ message: AmachToast) {
        currentToast = message
    }

    // ── Init ──────────────────────────────────────────────────

    init() {
        // Seed from UserDefaults / existing service state on launch.
        // Services update AppState directly once they initialize.
    }
}


// ============================================================
// MARK: - ENVIRONMENT KEY COMPATIBILITY
// ============================================================
//
// Provides a safe default so previews and tests don't crash
// if AppState isn't injected. In production, always inject
// a real AppState at the WindowGroup level.

extension AppState {
    static var preview: AppState {
        let state = AppState()
        state.isAuthenticated     = true
        state.walletAddress       = "0xd3adb33f…c0ffee"
        state.currentTier         = "GOLD"
        state.dataScore           = 82
        state.isHealthKitAuthorized = true
        state.isWalletConnected   = true
        state.onboardingComplete  = true
        return state
    }
}


// ============================================================
// MARK: - PREVIEW
// ============================================================

#Preview("AppState — Preview Values") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.md) {
            let state = AppState.preview

            AmachHealthScoreRing(score: state.dataScore, tier: state.currentTier)

            VStack(spacing: AmachSpacing.sm) {
                AmachStatRow("Tier") { AmachTierBadge(tier: state.currentTier) }
                AmachStatRow("Score", value: "\(state.dataScore) / 100")
                AmachStatRow("Wallet", value: state.walletAddress ?? "Not connected")
                AmachStatRow("HealthKit", value: state.isHealthKitAuthorized ? "Authorized" : "Not authorized")
                AmachStatRow("Fully connected", value: state.isFullyConnected ? "Yes" : "No")
            }
            .padding()
            .amachCard()
            .padding()
        }
    }
    .preferredColorScheme(.dark)
}
