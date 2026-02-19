// AmachHealthApp.swift
// Main entry point — 5-tab dark premium app

import SwiftUI

@main
struct AmachHealthApp: App {
    @StateObject private var healthKit = HealthKitService.shared
    @StateObject private var wallet = WalletService.shared
    @StateObject private var syncService = HealthDataSyncService.shared
    @StateObject private var chatService = ChatService.shared
    @StateObject private var dashboard = DashboardService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(healthKit)
                .environmentObject(wallet)
                .environmentObject(syncService)
                .environmentObject(chatService)
                .environmentObject(dashboard)
                .preferredColorScheme(.dark)
                .task {
                    if healthKit.isHealthKitAvailable && !healthKit.isAuthorized {
                        try? await healthKit.requestAuthorization()
                    }
                }
        }
    }
}

// MARK: - Root Navigation

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "chart.xyaxis.line")
                }

            ChatView()
                .tabItem {
                    Label("Cosaint", systemImage: "sparkles")
                }

            HealthSyncView()
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }

            AttestationsView()
                .tabItem {
                    Label("Proofs", systemImage: "checkmark.seal.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(Color.amachPrimaryBright)
        .onAppear {
            // Dark tab bar styling
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(Color.amachBg)
            appearance.shadowColor = UIColor(Color.amachPrimary.opacity(0.15))
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance

            // Dark navigation bar styling
            let navAppearance = UINavigationBarAppearance()
            navAppearance.configureWithOpaqueBackground()
            navAppearance.backgroundColor = UIColor(Color.amachBg)
            navAppearance.titleTextAttributes = [.foregroundColor: UIColor(Color.amachTextPrimary)]
            navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor(Color.amachTextPrimary)]
            UINavigationBar.appearance().standardAppearance = navAppearance
            UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        }
    }
}

// MARK: - Attestations View

struct AttestationsView: View {
    @State private var attestations: [AttestationInfo] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                Group {
                    if isLoading {
                        loadingView
                    } else if let error {
                        errorView(error)
                    } else if attestations.isEmpty {
                        emptyView
                    } else {
                        attestationList
                    }
                }
            }
            .navigationTitle("On-Chain Proofs")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(Color.amachPrimaryBright)
            Text("Loading attestations…")
                .font(.caption)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.amachAccent)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(Color.amachTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.amachPrimary.opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.amachPrimary.opacity(0.5))
            }
            Text("No attestations yet")
                .font(.headline)
                .foregroundStyle(Color.amachTextPrimary)
            Text("Sync your health data to create verifiable on-chain proofs")
                .font(.subheadline)
                .foregroundStyle(Color.amachTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attestationList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(attestations) { attestation in
                    AttestationCard(attestation: attestation)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func load() async {
        guard let address = WalletService.shared.address else {
            error = "Connect wallet to view attestations"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            attestations = try await AmachAPIClient.shared.getAttestations(walletAddress: address)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AttestationCard: View {
    let attestation: AttestationInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: dataTypeIcon(attestation.dataType))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.amachPrimaryBright)
                        .frame(width: 28, height: 28)
                        .background(Color.amachPrimary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(attestation.dataTypeName)
                        .font(.headline)
                        .foregroundStyle(Color.amachTextPrimary)
                }
                Spacer()
                TierBadge(tier: attestation.tier.rawValue)
            }

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Completeness")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                    Text("\(attestation.completenessScore / 100)%")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.amachTextPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Attested")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                    Text(Date(timeIntervalSince1970: attestation.timestamp), style: .date)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.amachTextPrimary)
                }
            }

            // Hash preview
            Text(String(attestation.contentHash.prefix(20)) + "…")
                .font(.caption2)
                .foregroundStyle(Color.amachTextSecondary)
                .fontDesign(.monospaced)
        }
        .padding(16)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1)
        )
    }

    private func dataTypeIcon(_ type: Int) -> String {
        switch type {
        case 0: return "medical.thermometer.fill"   // DEXA
        case 1: return "drop.fill"                   // Bloodwork
        case 2: return "heart.fill"                  // Apple Health
        case 3: return "waveform.path.ecg"           // CGM
        default: return "doc.fill"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var wallet: WalletService
    @EnvironmentObject var healthKit: HealthKitService

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                List {
                    // Account
                    Section {
                        if wallet.isConnected, let address = wallet.address {
                            settingsRow(
                                icon: "wallet.pass.fill",
                                iconColor: Color.amachPrimaryBright,
                                title: "Wallet",
                                value: truncate(address)
                            )

                            Button(role: .destructive) {
                                Task { await wallet.disconnect() }
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.right.square.fill")
                                        .foregroundStyle(Color(hex: "F87171"))
                                    Text("Disconnect Wallet")
                                        .foregroundStyle(Color(hex: "F87171"))
                                }
                            }
                            .listRowBackground(Color.amachSurface)
                        } else {
                            Button {
                                Task { try? await wallet.connect() }
                            } label: {
                                HStack {
                                    Image(systemName: "wallet.pass.fill")
                                        .foregroundStyle(Color.amachPrimaryBright)
                                    Text("Connect Wallet")
                                        .foregroundStyle(Color.amachPrimaryBright)
                                        .fontWeight(.medium)
                                }
                            }
                            .listRowBackground(Color.amachSurface)
                        }
                    } header: {
                        sectionHeader("Account")
                    }

                    // Health Data
                    Section {
                        settingsRow(
                            icon: "heart.fill",
                            iconColor: Color(hex: "F87171"),
                            title: "HealthKit",
                            value: healthKit.isAuthorized ? "Authorized" : "Not Authorized",
                            valueColor: healthKit.isAuthorized ? Color.amachPrimaryBright : Color.amachTextSecondary
                        )

                        if !healthKit.isAuthorized {
                            Button {
                                Task { try? await healthKit.requestAuthorization() }
                            } label: {
                                HStack {
                                    Image(systemName: "lock.open.fill")
                                        .foregroundStyle(Color.amachPrimaryBright)
                                    Text("Authorize HealthKit")
                                        .foregroundStyle(Color.amachPrimaryBright)
                                        .fontWeight(.medium)
                                }
                            }
                            .listRowBackground(Color.amachSurface)
                        }
                    } header: {
                        sectionHeader("Health Data")
                    }

                    // Platform
                    Section {
                        settingsRow(
                            icon: "globe",
                            iconColor: Color.amachPrimary,
                            title: "Web App",
                            value: "app.amach.health"
                        )
                        settingsRow(
                            icon: "lock.shield.fill",
                            iconColor: Color.amachPrimary,
                            title: "Storage",
                            value: "Storj (Encrypted)"
                        )
                        settingsRow(
                            icon: "link.circle.fill",
                            iconColor: Color.amachAccent,
                            title: "Network",
                            value: "ZKsync Era"
                        )
                    } header: {
                        sectionHeader("Platform")
                    }

                    // About
                    Section {
                        settingsRow(
                            icon: "info.circle.fill",
                            iconColor: Color.amachTextSecondary,
                            title: "Version",
                            value: "1.0.0"
                        )

                        Link(destination: URL(string: "https://amach.health/privacy")!) {
                            HStack {
                                Image(systemName: "hand.raised.fill")
                                    .foregroundStyle(Color.amachTextSecondary)
                                    .frame(width: 28)
                                Text("Privacy Policy")
                                    .foregroundStyle(Color.amachTextPrimary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(Color.amachTextSecondary)
                            }
                        }
                        .listRowBackground(Color.amachSurface)

                        Link(destination: URL(string: "https://amach.health/terms")!) {
                            HStack {
                                Image(systemName: "doc.text.fill")
                                    .foregroundStyle(Color.amachTextSecondary)
                                    .frame(width: 28)
                                Text("Terms of Service")
                                    .foregroundStyle(Color.amachTextPrimary)
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.caption)
                                    .foregroundStyle(Color.amachTextSecondary)
                            }
                        }
                        .listRowBackground(Color.amachSurface)
                    } header: {
                        sectionHeader("About")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func settingsRow(
        icon: String,
        iconColor: Color,
        title: String,
        value: String,
        valueColor: Color = Color(hex: "9CA3AF")
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 28)
            Text(title)
                .foregroundStyle(Color.amachTextPrimary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(valueColor)
        }
        .listRowBackground(Color.amachSurface)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.amachTextSecondary)
            .tracking(1)
    }

    private func truncate(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }
}

// MARK: - Shared UI Components

struct TierBadge: View {
    let tier: String

    private var config: (bg: Color, fg: Color) {
        switch tier.uppercased() {
        case "GOLD":   return (Color.amachAccent.opacity(0.15), Color.amachAccent)
        case "SILVER": return (Color.amachSilver.opacity(0.15), Color.amachSilver)
        case "BRONZE": return (Color.amachBronze.opacity(0.15), Color.amachBronze)
        default:       return (Color.amachSurface, Color.amachTextSecondary)
        }
    }

    var body: some View {
        Text(tier.uppercased())
            .font(.caption2)
            .fontWeight(.bold)
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(config.bg)
            .foregroundStyle(config.fg)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(config.fg.opacity(0.3), lineWidth: 1)
            )
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    // MARK: Dark Premium Palette
    static let amachBg             = Color(hex: "0A0E1A")  // Deep navy background
    static let amachSurface        = Color(hex: "111827")  // Card surface
    static let amachSurfaceElevated = Color(hex: "1A2234") // Elevated card

    static let amachPrimary        = Color(hex: "10B981")  // Emerald (web: hsl 142 76% 36%)
    static let amachPrimaryBright  = Color(hex: "34D399")  // Emerald-400, pops on dark bg

    static let amachAccent         = Color(hex: "F59E0B")  // Amber-500
    static let amachGold           = Color(hex: "F59E0B")
    static let amachSilver         = Color(hex: "94A3B8")
    static let amachBronze         = Color(hex: "CD7F32")

    static let amachTextPrimary    = Color(hex: "F9FAFB")  // Near white
    static let amachTextSecondary  = Color(hex: "9CA3AF")  // Muted gray

    static let amachDestructive    = Color(hex: "F87171")  // Red-400
}

// MARK: - View Helpers

extension View {
    func amachCard() -> some View {
        self
            .background(Color.amachSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.amachPrimary.opacity(0.12), lineWidth: 1)
            )
    }

    func amachGlow() -> some View {
        self.shadow(color: Color.amachPrimary.opacity(0.3), radius: 12, x: 0, y: 4)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(HealthKitService.shared)
        .environmentObject(WalletService.shared)
        .environmentObject(HealthDataSyncService.shared)
        .environmentObject(ChatService.shared)
        .environmentObject(DashboardService.shared)
}
