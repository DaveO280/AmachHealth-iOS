// HealthSyncView.swift
// AmachHealth
//
// Main view for health data sync and status display

import SwiftUI

struct HealthSyncView: View {
    @StateObject private var healthKit = HealthKitService.shared
    @StateObject private var wallet = WalletService.shared
    @StateObject private var syncService = HealthDataSyncService.shared

    @State private var showingDatePicker = false
    @State private var syncStartDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Connection Status Cards
                    connectionStatusSection

                    // Sync Status
                    if case .syncing = syncService.syncState {
                        syncProgressSection
                    }

                    // Last Sync Result
                    if let result = syncService.lastSyncResult {
                        lastSyncResultSection(result: result)
                    }

                    // Sync Button
                    syncButtonSection

                    // Storage List
                    NavigationLink {
                        StorageListView()
                    } label: {
                        HStack {
                            Image(systemName: "externaldrive.fill")
                            Text("View Stored Data")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
            }
            .navigationTitle("Health Sync")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if syncService.syncState.isLoading {
                        ProgressView()
                    }
                }
            }
        }
    }

    // MARK: - Connection Status

    private var connectionStatusSection: some View {
        VStack(spacing: 12) {
            // HealthKit Status
            HStack {
                Image(systemName: healthKit.isAuthorized ? "heart.fill" : "heart")
                    .foregroundStyle(healthKit.isAuthorized ? .red : .gray)
                VStack(alignment: .leading) {
                    Text("HealthKit")
                        .font(.headline)
                    Text(healthKit.isAuthorized ? "Connected" : "Not authorized")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !healthKit.isAuthorized {
                    Button("Authorize") {
                        Task {
                            try? await healthKit.requestAuthorization()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            // Wallet Status
            HStack {
                Image(systemName: wallet.isConnected ? "wallet.pass.fill" : "wallet.pass")
                    .foregroundStyle(wallet.isConnected ? .green : .gray)
                VStack(alignment: .leading) {
                    Text("Wallet")
                        .font(.headline)
                    if let address = wallet.address {
                        Text(truncateAddress(address))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !wallet.isConnected {
                    Button("Connect") {
                        Task {
                            try? await wallet.connect()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }

    // MARK: - Sync Progress

    private var syncProgressSection: some View {
        VStack(spacing: 12) {
            ProgressView(value: syncService.syncState.progress)
                .tint(.blue)

            if let message = syncService.syncState.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Last Sync Result

    private func lastSyncResultSection(result: SyncResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.success ? .green : .red)
                Text(result.success ? "Last Sync Successful" : "Last Sync Failed")
                    .font(.headline)
                Spacer()
                if let date = syncService.lastSyncDate {
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if result.success {
                // Tier badge
                if let tier = result.tier {
                    HStack {
                        tierBadge(tier: tier)
                        if let score = result.score {
                            Text("\(score)% complete")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Stats
                HStack(spacing: 16) {
                    if let metrics = result.metricsCount {
                        statItem(value: "\(metrics)", label: "Metrics")
                    }
                    if let days = result.daysCovered {
                        statItem(value: "\(days)", label: "Days")
                    }
                }
            } else if let error = result.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)

                Button("Retry") {
                    Task {
                        await syncService.retrySync()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    // MARK: - Sync Button

    private var syncButtonSection: some View {
        VStack(spacing: 12) {
            Button {
                showingDatePicker = true
            } label: {
                HStack {
                    Text("Sync from:")
                    Spacer()
                    Text(syncStartDate, style: .date)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            Button {
                Task {
                    await syncService.performFullSync(from: syncStartDate)
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Sync Health Data")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSync)
        }
        .sheet(isPresented: $showingDatePicker) {
            DatePicker(
                "Sync from",
                selection: $syncStartDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .presentationDetents([.medium])
            .padding()
        }
    }

    // MARK: - Helpers

    private var canSync: Bool {
        healthKit.isAuthorized &&
        wallet.isConnected &&
        !syncService.syncState.isLoading
    }

    private func truncateAddress(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }

    private func tierBadge(tier: String) -> some View {
        let color: Color = {
            switch tier.uppercased() {
            case "GOLD": return .yellow
            case "SILVER": return .gray
            case "BRONZE": return .orange
            default: return .gray
            }
        }()

        return Text(tier)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(6)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Storage List View

struct StorageListView: View {
    @State private var items: [StorjListItem] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let error = error {
                Text(error)
                    .foregroundStyle(.red)
            } else if items.isEmpty {
                Text("No stored health data")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    StorageItemRow(item: item)
                }
            }
        }
        .navigationTitle("Stored Data")
        .task {
            await loadItems()
        }
        .refreshable {
            await loadItems()
        }
    }

    private func loadItems() async {
        guard let encryptionKey = WalletService.shared.encryptionKey else {
            error = "Wallet not connected"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            items = try await AmachAPIClient.shared.listHealthData(
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey,
                dataType: "apple-health-full-export"
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct StorageItemRow: View {
    let item: StorjListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apple Health Export")
                    .font(.headline)
                Spacer()
                if let tier = item.tier {
                    tierBadge(tier: tier)
                }
            }

            if let dateRange = item.dateRange {
                Text("\(dateRange.start) to \(dateRange.end)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if let count = item.metricsCount {
                    Text("\(count) metrics")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.uploadDate, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func tierBadge(tier: String) -> some View {
        let color: Color = {
            switch tier.uppercased() {
            case "GOLD": return .yellow
            case "SILVER": return .gray
            case "BRONZE": return .orange
            default: return .gray
            }
        }()

        return Text(tier)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .cornerRadius(4)
    }
}

// MARK: - Preview

#Preview {
    HealthSyncView()
}
