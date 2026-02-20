// ProfileView.swift
// AmachHealth
//
// Tab 4: Profile, wallet, data quality, settings, attestations.
//
// Layout:
//   ProfileHeader     wallet address + tier badge + data score
//   ConnectedSources  HealthKit status card
//   DataQuality       tier explanation + score ring
//   Attestations      on-chain proof list (inline)
//   Privacy           data controls
//   Preferences       notifications, units, theme
//   About             version, links
//   Destructive       disconnect wallet, delete account (with confirmation)

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var wallet: WalletService
    @EnvironmentObject private var healthKit: HealthKitService
    @EnvironmentObject private var syncService: HealthDataSyncService

    @State private var attestations: [AttestationInfo] = []
    @State private var isLoadingAttestations = false
    @State private var showDisconnectAlert = false
    @State private var showDeleteAlert = false
    @State private var showingOpenSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                List {
                    profileHeaderSection
                    connectedSourcesSection
                    dataQualitySection
                    attestationsSection
                    privacySection
                    aboutSection
                    destructiveSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task { await loadAttestations() }
            .alert("Disconnect Wallet", isPresented: $showDisconnectAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Disconnect", role: .destructive) {
                    Task { await wallet.disconnect() }
                }
            } message: {
                Text("Your data will remain in your Storj vault. You can reconnect anytime.")
            }
            .alert("Delete Account", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Everything", role: .destructive) {
                    // Placeholder — requires backend call
                }
            } message: {
                Text("This permanently deletes your Amach account and all stored data. This cannot be undone.")
            }
        }
    }

    // MARK: - Profile Header

    private var profileHeaderSection: some View {
        Section {
            VStack(spacing: AmachSpacing.md) {
                // Avatar placeholder + address
                HStack(spacing: AmachSpacing.md) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.amachPrimaryBright.opacity(0.4), Color.amachPrimary.opacity(0.2)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 56, height: 56)
                        Image(systemName: "person.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color.amachPrimaryBright)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        if wallet.isConnected, let address = wallet.address {
                            Text(truncate(address))
                                .font(AmachType.dataValue(size: 16))
                                .foregroundStyle(Color.amachTextPrimary)
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.amachSuccess)
                                    .frame(width: 6, height: 6)
                                Text("Wallet connected")
                                    .font(AmachType.tiny)
                                    .foregroundStyle(Color.amachSuccess)
                            }
                        } else {
                            Text("No wallet")
                                .font(AmachType.h3)
                                .foregroundStyle(Color.amachTextSecondary)
                            Text("Connect to sync and verify data")
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.amachTextSecondary)
                        }
                    }

                    Spacer()

                    // Tier badge
                    if let result = syncService.lastSyncResult, let tier = result.tier {
                        AmachTierBadge(tier: tier)
                    }
                }

                // Data score ring (if available)
                if let result = syncService.lastSyncResult, let score = result.score {
                    dataScoreRow(score: score)
                }
            }
            .padding(.vertical, AmachSpacing.sm)
            .listRowBackground(Color.amachSurface)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }

    private func dataScoreRow(score: Int) -> some View {
        HStack(spacing: AmachSpacing.md) {
            // Mini score ring
            ZStack {
                Circle()
                    .stroke(Color.amachPrimary.opacity(0.12), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(Color.amachPrimaryBright, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.amachTextPrimary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Data completeness score")
                    .font(AmachType.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.amachTextPrimary)
                Text("Higher score = richer insights from Luma")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            Spacer()
        }
        .padding(AmachSpacing.sm + 4)
        .background(Color.amachPrimary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
    }

    // MARK: - Connected Sources

    private var connectedSourcesSection: some View {
        Section {
            sourceRow(
                icon: "heart.fill",
                iconColor: Color(hex: "F87171"),
                title: "Apple Health",
                subtitle: healthKit.isAuthorized ? "Reading 35+ metrics" : "Not authorized",
                isConnected: healthKit.isAuthorized,
                action: healthKit.isAuthorized ? nil : {
                    Task { try? await healthKit.requestAuthorization() }
                },
                actionLabel: "Authorize"
            )

            sourceRow(
                icon: "wallet.pass.fill",
                iconColor: wallet.isConnected ? Color.amachPrimaryBright : Color.amachTextSecondary,
                title: "Wallet (Privy)",
                subtitle: wallet.isConnected ? truncate(wallet.address ?? "") : "Not connected",
                isConnected: wallet.isConnected,
                action: wallet.isConnected ? nil : {
                    Task { try? await wallet.connect() }
                },
                actionLabel: "Connect"
            )

            // Coming soon
            comingSoonRow(icon: "chart.dots.scatter", title: "CGM (Continuous Glucose)")
            comingSoonRow(icon: "figure.stand", title: "DEXA Scan")
        } header: {
            sectionHeader("Connected Sources")
        }
    }

    private func sourceRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isConnected: Bool,
        action: (() -> Void)?,
        actionLabel: String
    ) -> some View {
        HStack(spacing: AmachSpacing.md) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AmachType.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.amachTextPrimary)
                Text(subtitle)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            Spacer()

            if let action {
                Button(actionLabel, action: action)
                    .font(AmachType.tiny)
                    .fontWeight(.semibold)
                    .padding(.horizontal, AmachSpacing.sm)
                    .padding(.vertical, 5)
                    .background(Color.amachPrimary.opacity(0.12))
                    .foregroundStyle(Color.amachPrimaryBright)
                    .clipShape(Capsule())
            } else {
                HStack(spacing: 3) {
                    Circle().fill(Color.amachSuccess).frame(width: 5, height: 5)
                    Text("Active")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachSuccess)
                }
            }
        }
        .listRowBackground(Color.amachSurface)
    }

    private func comingSoonRow(icon: String, title: String) -> some View {
        HStack(spacing: AmachSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.amachTextSecondary.opacity(0.08))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.amachTextSecondary.opacity(0.4))
            }

            Text(title)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)

            Spacer()

            Text("SOON")
                .font(AmachType.tiny)
                .fontWeight(.bold)
                .tracking(0.5)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.amachTextSecondary.opacity(0.08))
                .foregroundStyle(Color.amachTextTertiary)
                .clipShape(RoundedRectangle(cornerRadius: AmachRadius.xs))
        }
        .listRowBackground(Color.amachSurface)
    }

    // MARK: - Data Quality

    private var dataQualitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                let tier = syncService.lastSyncResult?.tier ?? "NONE"
                HStack {
                    Text("Your tier")
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                    Spacer()
                    AmachTierBadge(tier: tier)
                }

                Divider().overlay(Color.amachPrimary.opacity(0.08))

                tierExplanation(tier: tier)
            }
            .listRowBackground(Color.amachSurface)

            // Prompt to sync
            HStack(spacing: AmachSpacing.md) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.amachTextSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync health data")
                        .font(AmachType.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.amachTextSecondary)
                    Text("Go to the Sync tab to upload your data")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
                }
            }
            .listRowBackground(Color.amachSurface)
        } header: {
            sectionHeader("Data Quality")
        } footer: {
            Text("Gold tier = 90+ days of core health metrics. Higher tiers unlock richer Luma analysis and higher on-chain attestation value.")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
                .lineSpacing(2)
        }
    }

    private func tierExplanation(tier: String) -> some View {
        let tiers: [(label: String, desc: String, isCurrent: Bool)] = [
            ("GOLD",   "90+ days, all core metrics", tier == "GOLD"),
            ("SILVER", "30+ days, most core metrics", tier == "SILVER"),
            ("BRONZE", "7+ days, some metrics", tier == "BRONZE"),
            ("NONE",   "Not yet synced", tier == "NONE"),
        ]

        return VStack(spacing: AmachSpacing.xs + 2) {
            ForEach(tiers, id: \.label) { t in
                HStack(spacing: AmachSpacing.sm) {
                    AmachTierBadge(tier: t.label)
                        .opacity(t.isCurrent ? 1 : 0.4)
                    Text(t.desc)
                        .font(AmachType.tiny)
                        .foregroundStyle(t.isCurrent ? Color.amachTextPrimary : Color.amachTextSecondary)
                    Spacer()
                    if t.isCurrent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.amachPrimaryBright)
                    }
                }
            }
        }
    }

    // MARK: - Attestations

    private var attestationsSection: some View {
        Section {
            if isLoadingAttestations {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(Color.amachPrimaryBright)
                    Spacer()
                }
                .listRowBackground(Color.amachSurface)
            } else if attestations.isEmpty {
                HStack(spacing: AmachSpacing.md) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.amachTextSecondary.opacity(0.4))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No on-chain proofs yet")
                            .font(AmachType.caption)
                            .foregroundStyle(Color.amachTextSecondary)
                        Text("Sync health data to create verifiable attestations.")
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
                    }
                }
                .listRowBackground(Color.amachSurface)
            } else {
                ForEach(attestations.prefix(3)) { attestation in
                    attestationRow(attestation)
                }

                if attestations.count > 3 {
                    Text("+ \(attestations.count - 3) more proofs")
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                        .listRowBackground(Color.amachSurface)
                }
            }
        } header: {
            sectionHeader("On-Chain Proofs")
        }
    }

    private func attestationRow(_ attestation: AttestationInfo) -> some View {
        HStack(spacing: AmachSpacing.md) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.amachPrimaryBright)

            VStack(alignment: .leading, spacing: 2) {
                Text(attestation.dataTypeName)
                    .font(AmachType.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.amachTextPrimary)
                Text(Date(timeIntervalSince1970: attestation.timestamp), style: .date)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            Spacer()

            AmachTierBadge(tier: attestation.tier.rawValue)
        }
        .listRowBackground(Color.amachSurface)
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            settingsRow(
                icon: "lock.shield.fill",
                iconColor: Color.amachPrimaryBright,
                title: "Storage",
                value: "Storj (AES-256)"
            )

            settingsRow(
                icon: "link.circle.fill",
                iconColor: Color.amachAccent,
                title: "Network",
                value: "ZKsync Era"
            )

            settingsRow(
                icon: "eye.slash.fill",
                iconColor: Color.amachTextSecondary,
                title: "Encryption",
                value: "End-to-end"
            )

            Link(destination: URL(string: "https://amach.health/privacy")!) {
                HStack {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(Color.amachTextSecondary)
                        .frame(width: 28)
                    Text("Privacy Policy")
                        .foregroundStyle(Color.amachTextPrimary)
                        .font(AmachType.caption)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
            .listRowBackground(Color.amachSurface)
        } header: {
            sectionHeader("Privacy & Security")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            settingsRow(
                icon: "info.circle.fill",
                iconColor: Color.amachTextSecondary,
                title: "Version",
                value: "1.0.0"
            )

            settingsRow(
                icon: "globe",
                iconColor: Color.amachPrimaryBright,
                title: "Web App",
                value: "app.amach.health"
            )

            Link(destination: URL(string: "https://amach.health/terms")!) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(Color.amachTextSecondary)
                        .frame(width: 28)
                    Text("Terms of Service")
                        .foregroundStyle(Color.amachTextPrimary)
                        .font(AmachType.caption)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
            .listRowBackground(Color.amachSurface)
        } header: {
            sectionHeader("About")
        }
    }

    // MARK: - Destructive Actions

    private var destructiveSection: some View {
        Section {
            if wallet.isConnected {
                Button(role: .destructive) {
                    showDisconnectAlert = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.square.fill")
                        Text("Disconnect Wallet")
                    }
                    .foregroundStyle(Color.amachDestructive)
                    .font(AmachType.caption)
                }
                .listRowBackground(Color.amachSurface)
            } else {
                Button {
                    Task { try? await wallet.connect() }
                } label: {
                    HStack {
                        Image(systemName: "wallet.pass.fill")
                        Text("Connect Wallet")
                    }
                    .foregroundStyle(Color.amachPrimaryBright)
                    .font(AmachType.caption)
                    .fontWeight(.medium)
                }
                .listRowBackground(Color.amachSurface)
            }

            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                HStack {
                    Image(systemName: "trash.fill")
                    Text("Delete Account & Data")
                }
                .foregroundStyle(Color.amachDestructive.opacity(0.7))
                .font(AmachType.caption)
            }
            .listRowBackground(Color.amachSurface)
        } header: {
            sectionHeader("Account")
        } footer: {
            Text("Deleting your account removes your Amach profile and all encrypted data from Storj. On-chain attestations remain on ZKsync Era (public blockchain).")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
                .lineSpacing(2)
        }
    }

    // MARK: - Helpers

    private func settingsRow(
        icon: String,
        iconColor: Color,
        title: String,
        value: String
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .frame(width: 28)
            Text(title)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextPrimary)
            Spacer()
            Text(value)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .listRowBackground(Color.amachSurface)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AmachType.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(Color.amachTextSecondary)
            .tracking(1)
    }

    private func truncate(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    private func loadAttestations() async {
        guard let address = wallet.address else { return }
        isLoadingAttestations = true
        defer { isLoadingAttestations = false }
        do {
            attestations = try await AmachAPIClient.shared.getAttestations(walletAddress: address)
        } catch {
            // Non-critical — attestations section just stays empty
        }
    }
}


// ============================================================
// MARK: - PREVIEW
// ============================================================

#Preview {
    ProfileView()
        .environmentObject(WalletService.shared)
        .environmentObject(HealthKitService.shared)
        .environmentObject(HealthDataSyncService.shared)
        .preferredColorScheme(.dark)
}
