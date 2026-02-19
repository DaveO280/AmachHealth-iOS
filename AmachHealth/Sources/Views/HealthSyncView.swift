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
    @State private var syncStartDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        connectionSection
                        syncProgressSection
                        lastSyncSection
                        syncControlSection
                        storageLink
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
                    Task { try? await wallet.connect() }
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

    // MARK: - Storage Link

    private var storageLink: some View {
        NavigationLink {
            StorageListView()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.amachPrimary.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.amachPrimaryBright)
                }
                Text("View Stored Data")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.amachTextPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
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
}

// MARK: - Storage List View

struct StorageListView: View {
    @State private var items: [StorjListItem] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            Group {
                if isLoading {
                    ProgressView().tint(Color.amachPrimaryBright)
                } else if let error {
                    Text(error)
                        .foregroundStyle(Color.amachDestructive)
                        .padding()
                } else if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "externaldrive")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.amachTextSecondary)
                        Text("No stored data yet")
                            .foregroundStyle(Color.amachTextSecondary)
                        Text("Sync health data to see it here")
                            .font(.caption)
                            .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(items) { item in
                                StorageItemCard(item: item)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
        }
        .navigationTitle("Stored Data")
        .navigationBarTitleDisplayMode(.large)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await loadItems() }
        .refreshable { await loadItems() }
    }

    private func loadItems() async {
        guard let key = WalletService.shared.encryptionKey else {
            error = "Wallet not connected"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await AmachAPIClient.shared.listHealthData(
                walletAddress: key.walletAddress,
                encryptionKey: key,
                dataType: "apple-health-full-export"
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct StorageItemCard: View {
    let item: StorjListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.amachPrimaryBright)
                        .frame(width: 26, height: 26)
                        .background(Color.amachPrimary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 7))

                    Text("Apple Health Export")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.amachTextPrimary)
                }
                Spacer()
                if let tier = item.tier {
                    TierBadge(tier: tier)
                }
            }

            if let range = item.dateRange {
                Text("\(range.start) → \(range.end)")
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            HStack {
                if let count = item.metricsCount {
                    Text("\(count) metrics")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                }
                Spacer()
                Text(item.uploadDate, style: .relative)
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .padding(14)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    HealthSyncView()
        .preferredColorScheme(.dark)
}
