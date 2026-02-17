// AmachHealthApp.swift
// Main entry point for the Amach Health iOS app

import SwiftUI

@main
struct AmachHealthApp: App {
    @StateObject private var healthKit = HealthKitService.shared
    @StateObject private var wallet = WalletService.shared
    @StateObject private var syncService = HealthDataSyncService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(healthKit)
                .environmentObject(wallet)
                .environmentObject(syncService)
                .task {
                    // Request HealthKit authorization on launch
                    if healthKit.isHealthKitAvailable && !healthKit.isAuthorized {
                        try? await healthKit.requestAuthorization()
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var wallet: WalletService

    var body: some View {
        TabView {
            HealthSyncView()
                .tabItem {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }

            AttestationsView()
                .tabItem {
                    Label("Attestations", systemImage: "checkmark.seal.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .tint(Color(hex: "006B4F"))
    }
}

// MARK: - Attestations View

struct AttestationsView: View {
    @State private var attestations: [AttestationInfo] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let error = error {
                    Text(error)
                        .foregroundStyle(.red)
                } else if attestations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No attestations yet")
                            .font(.headline)
                        Text("Sync your health data to create on-chain attestations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(attestations) { attestation in
                        AttestationRow(attestation: attestation)
                    }
                }
            }
            .navigationTitle("Attestations")
            .task {
                await loadAttestations()
            }
            .refreshable {
                await loadAttestations()
            }
        }
    }

    private func loadAttestations() async {
        guard let address = WalletService.shared.address else {
            error = "Connect wallet to view attestations"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            attestations = try await AmachAPIClient.shared.getAttestations(
                walletAddress: address
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AttestationRow: View {
    let attestation: AttestationInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(attestation.dataTypeName)
                    .font(.headline)
                Spacer()
                tierBadge(tier: attestation.tier)
            }

            HStack {
                Text("\(attestation.completenessScore / 100)% complete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Date(timeIntervalSince1970: attestation.timestamp), style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func tierBadge(tier: AttestationTier) -> some View {
        let (color, text): (Color, String) = {
            switch tier {
            case .gold: return (.yellow, "GOLD")
            case .silver: return (.gray, "SILVER")
            case .bronze: return (.orange, "BRONZE")
            case .none: return (.gray, "NONE")
            }
        }()

        return Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(4)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var wallet: WalletService
    @EnvironmentObject var healthKit: HealthKitService

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if wallet.isConnected, let address = wallet.address {
                        HStack {
                            Text("Wallet")
                            Spacer()
                            Text(truncateAddress(address))
                                .foregroundStyle(.secondary)
                        }

                        Button("Disconnect", role: .destructive) {
                            Task {
                                await wallet.disconnect()
                            }
                        }
                    } else {
                        Button("Connect Wallet") {
                            Task {
                                try? await wallet.connect()
                            }
                        }
                    }
                }

                Section("Health Data") {
                    HStack {
                        Text("HealthKit")
                        Spacer()
                        Text(healthKit.isAuthorized ? "Authorized" : "Not Authorized")
                            .foregroundStyle(healthKit.isAuthorized ? .green : .secondary)
                    }

                    if !healthKit.isAuthorized {
                        Button("Authorize HealthKit") {
                            Task {
                                try? await healthKit.requestAuthorization()
                            }
                        }
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundStyle(.secondary)
                    }

                    Link("Privacy Policy", destination: URL(string: "https://amach.health/privacy")!)

                    Link("Terms of Service", destination: URL(string: "https://amach.health/terms")!)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func truncateAddress(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
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
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
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
}

#Preview {
    ContentView()
        .environmentObject(HealthKitService.shared)
        .environmentObject(WalletService.shared)
        .environmentObject(HealthDataSyncService.shared)
}
