// HealthSyncView.swift
// AmachHealth
//
// Dark premium health sync screen

import SwiftUI

struct HealthSyncView: View {
    @StateObject private var healthKit = HealthKitService.shared
    @StateObject private var wallet = WalletService.shared
    @StateObject private var syncService = HealthDataSyncService.shared

    @State private var showingDatePicker = false
    @State private var showingConnectWallet = false
    @State private var showingUploadLabData = false
    @State private var showingImportPDF = false
    @State private var syncStartDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
    @State private var vaultLabs: [LabReportWithMarkers] = []
    @ObservedObject private var vault = LocalVault.shared
    @ObservedObject private var importer = StorjImportService.shared
    @State private var isLoadingLabRecords = false
    @State private var labError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        connectionSection
                        if vault.isOpen {
                            VaultStatusSection()
                        }
                        if wallet.isConnected || vault.isOpen {
                            syncProgressSection
                            lastSyncSection
                            syncControlSection
                            labRecordsSection
                        } else {
                            walletGateCard
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Health Sync")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if syncService.syncState.isLoading {
                        ProgressView()
                            .tint(Color.amachPrimaryBright)
                    }
                }
            }
            .sheet(isPresented: $showingDatePicker) {
                datePicker
            }
            .sheet(isPresented: $showingConnectWallet) {
                ConnectWalletSheet()
                    .environmentObject(wallet)
                    .presentationDetents([.medium])
                    .presentationBackground(Color.amachSurface)
            }
            .sheet(isPresented: $showingUploadLabData) {
                UploadLabDataSheet {
                    await loadLabRecords()
                }
                .environmentObject(wallet)
                .presentationDetents([.large])
                .presentationBackground(Color.amachSurface)
            }
            .sheet(isPresented: $showingImportPDF) {
                UploadPDFReportSheet {
                    await loadLabRecords()
                }
                .environmentObject(wallet)
                .presentationDetents([.large])
                .presentationBackground(Color.amachSurface)
            }
            .task(id: wallet.isConnected || vault.isOpen) {
                if wallet.isConnected || vault.isOpen {
                    await loadLabRecords()
                } else {
                    vaultLabs = []
                    labError = nil
                }
            }
            .onChange(of: importer.state) { _, _ in
                Task { await loadLabRecords() }
            }
            .onChange(of: syncService.lastSyncDate) { _, _ in
                guard wallet.isConnected else { return }
                Task { await loadLabRecords() }
            }
        }
    }

    // MARK: - Connection Status

    private var connectionSection: some View {
        VStack(spacing: 10) {
            connectionRow(
                icon: "heart.fill",
                iconColor: healthKit.isAuthorized ? Color(hex: "F87171") : Color.amachTextSecondary,
                title: "HealthKit",
                subtitle: healthKit.isAuthorized ? "Authorized" : "Not authorized",
                isConnected: healthKit.isAuthorized,
                action: healthKit.isAuthorized ? nil : {
                    Task { try? await healthKit.requestAuthorization() }
                },
                actionLabel: "Authorize"
            )

            connectionRow(
                icon: "wallet.pass.fill",
                iconColor: wallet.isConnected ? Color.amachPrimaryBright : Color.amachTextSecondary,
                title: "Wallet",
                subtitle: wallet.isConnected
                    ? truncate(wallet.address ?? "")
                    : "Not connected",
                isConnected: wallet.isConnected,
                action: wallet.isConnected ? nil : {
                    showingConnectWallet = true
                },
                actionLabel: "Connect"
            )
        }
    }

    private func connectionRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        isConnected: Bool,
        action: (() -> Void)?,
        actionLabel: String
    ) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.amachTextPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            Spacer()

            if let action {
                Button(actionLabel, action: action)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.amachPrimary.opacity(0.15))
                    .foregroundStyle(Color.amachPrimaryBright)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.amachPrimary.opacity(0.3), lineWidth: 1))
            } else {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.amachPrimaryBright)
                        .frame(width: 6, height: 6)
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(Color.amachPrimaryBright)
                }
            }
        }
        .padding(14)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isConnected
                        ? Color.amachPrimary.opacity(0.2)
                        : Color.amachPrimary.opacity(0.08),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Sync Progress

    @ViewBuilder
    private var syncProgressSection: some View {
        if case .syncing(let progress, let message) = syncService.syncState {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(Color.amachPrimaryBright)
                        .rotationEffect(.degrees(syncService.syncState.isLoading ? 360 : 0))
                        .animation(
                            .linear(duration: 1).repeatForever(autoreverses: false),
                            value: syncService.syncState.isLoading
                        )
                    Text("Syncing…")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.amachTextPrimary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.amachPrimaryBright)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.amachPrimary.opacity(0.15))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.amachPrimaryBright)
                            .frame(width: geo.size.width * progress, height: 6)
                            .shadow(color: Color.amachPrimary.opacity(0.5), radius: 4)
                            .animation(.easeInOut(duration: 0.3), value: progress)
                    }
                }
                .frame(height: 6)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            .padding(16)
            .background(Color.amachSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.amachPrimary.opacity(0.2), lineWidth: 1)
            )
        }
    }

    // MARK: - Last Sync Result

    @ViewBuilder
    private var lastSyncSection: some View {
        if let result = syncService.lastSyncResult {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(
                        systemName: result.success
                            ? "checkmark.circle.fill"
                            : "xmark.circle.fill"
                    )
                    .foregroundStyle(result.success ? Color.amachPrimaryBright : Color.amachDestructive)

                    Text(result.success ? "Sync Successful" : "Sync Failed")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.amachTextPrimary)

                    Spacer()

                    if let date = syncService.lastSyncDate {
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                }

                if result.success {
                    HStack(spacing: 10) {
                        if let tier = result.tier {
                            TierBadge(tier: tier)
                        }
                        if let score = result.score {
                            Text("\(score)% complete")
                                .font(.subheadline)
                                .foregroundStyle(Color.amachTextSecondary)
                        }
                    }

                    HStack(spacing: 24) {
                        if let metrics = result.metricsCount {
                            statPill(value: "\(metrics)", label: "Metrics")
                        }
                        if let days = result.daysCovered {
                            statPill(value: "\(days)", label: "Days")
                        }
                    }

                    if let txHash = result.attestationTxHash {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Verified on ZKsync", systemImage: "checkmark.seal.fill")
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.amachSuccess)
                            Text(shortHash(txHash))
                                .font(AmachType.dataMono)
                                .foregroundStyle(Color.amachTextSecondary)
                        }
                    }
                } else if let err = result.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(Color.amachDestructive)

                    Button {
                        Task { await syncService.retrySync() }
                    } label: {
                        Text("Retry Upload")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.amachDestructive.opacity(0.12))
                            .foregroundStyle(Color.amachDestructive)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.amachDestructive.opacity(0.3), lineWidth: 1))
                    }
                }
            }
            .padding(16)
            .background(Color.amachSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        result.success
                            ? Color.amachPrimary.opacity(0.2)
                            : Color.amachDestructive.opacity(0.2),
                        lineWidth: 1
                    )
            )
        }
    }

    // MARK: - Sync Controls

    private var syncControlSection: some View {
        VStack(spacing: 12) {
            Button {
                showingDatePicker = true
            } label: {
                HStack {
                    Image(systemName: "calendar")
                        .foregroundStyle(Color.amachPrimaryBright)
                    Text("Sync from")
                        .foregroundStyle(Color.amachTextPrimary)
                    Spacer()
                    Text(syncStartDate, style: .date)
                        .font(.subheadline)
                        .foregroundStyle(Color.amachTextSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Color.amachTextSecondary)
                }
                .padding(14)
                .background(Color.amachSurface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button {
                Task { await syncService.performFullSync(from: syncStartDate) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Sync Health Data")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    canSync
                        ? Color.amachPrimary
                        : Color.amachSurface
                )
                .foregroundStyle(canSync ? .white : Color.amachTextSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(
                    color: canSync ? Color.amachPrimary.opacity(0.4) : .clear,
                    radius: 12
                )
            }
            .disabled(!canSync)
            // Merkle genesis and coverage proofs are off until Phase 6 rebuilds
            // them on the phone (FeatureFlags.zkServerFlowsDisabled).
        }
    }

    private var datePicker: some View {
        VStack {
            DatePicker(
                "Sync from",
                selection: $syncStartDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .tint(Color.amachPrimaryBright)
            .padding()
        }
        .presentationDetents([.medium])
        .presentationBackground(Color.amachSurface)
    }

    // MARK: - Lab Records

    private var labRecordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lab & Records")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.amachTextPrimary)
                    Text("Luma can read these to personalize your insights.")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        showingImportPDF = true
                    } label: {
                        Label("Import PDF", systemImage: "doc.badge.plus")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.amachPrimary.opacity(0.15))
                    .foregroundStyle(Color.amachPrimaryBright)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.amachPrimary.opacity(0.25), lineWidth: 1))

                    Button("Upload") {
                        showingUploadLabData = true
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.amachPrimary.opacity(0.15))
                    .foregroundStyle(Color.amachPrimaryBright)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.amachPrimary.opacity(0.25), lineWidth: 1))
                }
            }

            if isLoadingLabRecords {
                ProgressView()
                    .tint(Color.amachPrimaryBright)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else if let labError {
                Text(labError)
                    .font(.caption)
                    .foregroundStyle(Color.amachDestructive)
            } else if vault.isOpen {
                if vaultLabs.isEmpty {
                    Text("No lab reports stored yet.")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 10) {
                        ForEach(vaultLabs) { report in
                            NavigationLink {
                                LabRecordDetailView(vaultItem: report, onDeleted: { await loadLabRecords() })
                                    .environmentObject(wallet)
                            } label: {
                                VaultLabReportCard(report: report)
                            }
                            .buttonStyle(.plain)
                        }
                        NavigationLink {
                            VaultReportsView(onChange: { await loadLabRecords() })
                        } label: {
                            HStack {
                                Image(systemName: "tray.full")
                                Text("Manage reports")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.amachPrimaryBright)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Wallet Gate

    private var walletGateCard: some View {
        VStack(alignment: .leading, spacing: 20) {

            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.amachPrimary.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.amachPrimaryBright)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock Cloud Sync")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.amachTextPrimary)
                    Text("Connect a wallet for encrypted storage & rewards")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }

            // Feature list
            VStack(alignment: .leading, spacing: 10) {
                featureRow(icon: "externaldrive.fill",             text: "Encrypted storage on Storj")
                featureRow(icon: "chart.line.uptrend.xyaxis",     text: "Long-term health trends")
                featureRow(icon: "arrow.triangle.2.circlepath",   text: "Cross-device sync")
                featureRow(icon: "star.fill",                     text: "Earn rewards for your data")
            }

            // CTAs
            VStack(spacing: 10) {
                Link(destination: URL(string: "https://amachhealth.com")!) {
                    HStack(spacing: 6) {
                        Text("Request Early Access")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 18)
                    .background(Color.amachPrimary)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button { showingConnectWallet = true } label: {
                    Text("Connect Existing Wallet")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.amachPrimary.opacity(0.1))
                        .foregroundStyle(Color.amachPrimaryBright)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.amachPrimary.opacity(0.25), lineWidth: 1)
                        )
                }
            }
        }
        .padding(18)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.amachPrimary.opacity(0.15), lineWidth: 1)
        )
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.amachPrimaryBright)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.amachTextSecondary)
        }
    }

    // MARK: - Helpers

    private var canSync: Bool {
        healthKit.isAuthorized && wallet.isConnected && !syncService.syncState.isLoading
    }

    private func truncate(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    private func statPill(value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(Color.amachTextPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.amachTextSecondary)
        }
    }

    private func loadLabRecords() async {
        vaultLabs = (try? vault.database?.labReports()) ?? []
        labError = nil
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 16 else { return hash }
        return "\(hash.prefix(10))…\(hash.suffix(6))"
    }
}


// MARK: - Preview

#Preview {
    HealthSyncView()
        .preferredColorScheme(.dark)
}
