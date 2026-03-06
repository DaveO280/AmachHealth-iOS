// StorageDetailView.swift
// AmachHealth

import SwiftUI

struct StorageDetailView: View {
    let item: StorjListItem

    @EnvironmentObject private var wallet: WalletService
    @EnvironmentObject private var syncService: HealthDataSyncService

    @State private var payload: AppleHealthStorjPayload?
    @State private var isLoading = true
    @State private var error: String?
    @State private var expandedDays: Set<String> = []

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            Group {
                if isLoading {
                    ProgressView()
                        .tint(Color.amachPrimaryBright)
                } else if let error {
                    VStack(spacing: AmachSpacing.md) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Color.amachWarning)
                        Text(error)
                            .font(AmachType.body)
                            .foregroundStyle(Color.amachTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(AmachSpacing.lg)
                } else if let payload {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                            headerCard(payload)
                            summaryCard(payload)
                            metricsCard(payload)
                            dailySummariesCard(payload)
                        }
                        .padding(AmachSpacing.md)
                    }
                }
            }
        }
        .navigationTitle("Health Data")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPayload() }
    }

    private func headerCard(_ payload: AppleHealthStorjPayload) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(payload.manifest.dateRange.start) – \(payload.manifest.dateRange.end)")
                        .font(AmachType.h3)
                        .foregroundStyle(Color.amachTextPrimary)
                    Text("iOS export")
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                }

                Spacer()

                AmachTierBadge(tier: payload.manifest.completeness.tier)
            }

            if let txHash = attestationTxHash {
                Label("Verified on ZKsync", systemImage: "checkmark.seal.fill")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachSuccess)

                Text(shortHash(txHash))
                    .font(AmachType.dataMono)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func summaryCard(_ payload: AppleHealthStorjPayload) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            Text("Summary")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            HStack(spacing: AmachSpacing.md) {
                summaryStat("\(payload.manifest.completeness.score)%", label: "Completeness")
                summaryStat("\(payload.manifest.metricsPresent.count)", label: "Metrics")
                summaryStat("\(payload.manifest.completeness.recordCount)", label: "Records")
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func metricsCard(_ payload: AppleHealthStorjPayload) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            Text("Metrics Present")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            LazyVGrid(columns: AmachLayout.twoColumnGrid, spacing: AmachSpacing.sm) {
                ForEach(payload.manifest.metricsPresent.sorted(), id: \.self) { metric in
                    Text(metricDisplayName(metric))
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AmachSpacing.sm)
                        .padding(.vertical, 10)
                        .background(Color.amachPrimary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
                }
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func dailySummariesCard(_ payload: AppleHealthStorjPayload) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            Text("Daily Summaries")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            ForEach(payload.dailySummaries.keys.sorted(by: >), id: \.self) { day in
                let isExpanded = expandedDays.contains(day)
                let summary = payload.dailySummaries[day]

                VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                    Button {
                        withAnimation(AmachAnimation.normal) {
                            if isExpanded {
                                expandedDays.remove(day)
                            } else {
                                expandedDays.insert(day)
                            }
                        }
                    } label: {
                        HStack(spacing: AmachSpacing.sm) {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.amachTextSecondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(day)
                                    .font(AmachType.caption)
                                    .foregroundStyle(Color.amachTextPrimary)
                                Text(daySummaryLine(summary))
                                    .font(AmachType.tiny)
                                    .foregroundStyle(Color.amachTextSecondary)
                            }

                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    if isExpanded, let summary {
                        VStack(alignment: .leading, spacing: 8) {
                            if let sleep = summary.sleep {
                                Text("Sleep: \(sleep.total / 60)h \(sleep.total % 60)m")
                                    .font(AmachType.caption)
                                    .foregroundStyle(Color.amachTextPrimary)
                            }

                            ForEach(summary.metrics.keys.sorted(), id: \.self) { key in
                                let metric = summary.metrics[key]
                                HStack {
                                    Text(metricDisplayName(key))
                                        .font(AmachType.caption)
                                        .foregroundStyle(Color.amachTextSecondary)
                                    Spacer()
                                    Text(metricValueLine(metric))
                                        .font(AmachType.dataMono)
                                        .foregroundStyle(Color.amachTextPrimary)
                                }
                            }
                        }
                        .padding(.leading, 20)
                    }
                }
                .padding(.vertical, AmachSpacing.xs)
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func summaryStat(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(AmachType.dataValue(size: 18))
                .foregroundStyle(Color.amachTextPrimary)
            Text(label)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadPayload() async {
        guard let encryptionKey = wallet.encryptionKey else {
            error = "Wallet not connected"
            isLoading = false
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            payload = try await AmachAPIClient.shared.retrieveHealthData(
                storjUri: item.uri,
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var attestationTxHash: String? {
        item.attestationTxHash
            ?? {
                guard syncService.lastSyncResult?.storjUri == item.uri else { return nil }
                return syncService.lastSyncResult?.attestationTxHash
            }()
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 16 else { return hash }
        return "\(hash.prefix(10))…\(hash.suffix(6))"
    }

    private func metricDisplayName(_ key: String) -> String {
        key
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private func daySummaryLine(_ summary: DailySummary?) -> String {
        guard let summary else { return "No data" }

        var parts: [String] = []

        if let steps = summary.metrics["StepCount"]?.total ?? summary.metrics["stepCount"]?.total {
            parts.append("Steps \(Int(steps))")
        }
        if let heartRate = summary.metrics["HeartRate"]?.avg ?? summary.metrics["heartRate"]?.avg {
            parts.append("HR \(Int(heartRate))")
        }
        if let sleep = summary.sleep?.total {
            parts.append("Sleep \(sleep / 60)h")
        }

        return parts.isEmpty ? "Tap to inspect metrics" : parts.joined(separator: "  •  ")
    }

    private func metricValueLine(_ metric: MetricSummary?) -> String {
        guard let metric else { return "No data" }

        if let total = metric.total {
            return NumberFormatter.localizedString(from: NSNumber(value: total), number: .decimal)
        }
        if let average = metric.avg {
            return String(format: "%.1f", average)
        }
        if let minimum = metric.min, let maximum = metric.max {
            return "\(String(format: "%.1f", minimum))–\(String(format: "%.1f", maximum))"
        }
        return "\(metric.count)"
    }
}
