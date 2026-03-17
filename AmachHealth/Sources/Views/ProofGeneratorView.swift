// ProofGeneratorView.swift
// AmachHealth
//
// Entry point for creating health metric proofs from the iOS app.
// Uses the ProofableMetric registry to auto-discover available metrics.

import SwiftUI

// MARK: - Legacy ProofOption (kept for backward compatibility)

struct ProofOption: Identifiable {
    let id: String
    let title: String
    let subtitle: () -> String
    let icon: String
    let isAvailable: () -> Bool
    let generate: () async throws -> Void
}

// MARK: - View

struct ProofGeneratorView: View {
    @EnvironmentObject private var wallet: WalletService
    @StateObject private var proofService = HealthMetricProofService.shared

    @State private var selectedCategory: ProofableMetricCategory?
    @State private var selectedMetric: ProofableMetric?
    @State private var selectedPeriod: TrendPeriod = .month

    @State private var generatingMetricId: String?
    @State private var error: String?

    @State private var latestLabSummary: LabResultSummary?
    @State private var latestDexaSummary: DexaResultSummary?
    @State private var isLoadingSummaries = true

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                    header

                    categoryPicker

                    if !filteredMetrics.isEmpty {
                        metricList
                    }

                    if let metric = selectedMetric, !metric.supportedPeriods.isEmpty {
                        periodPicker(for: metric)
                    }

                    if selectedMetric != nil {
                        generateButton
                    }

                    if let proof = proofService.lastGeneratedProof {
                        NavigationLink {
                            ProofDetailView(proof: proof)
                        } label: {
                            recentProofCard(for: proof)
                        }
                        .buttonStyle(.plain)
                    }

                    if let error {
                        Text(error)
                            .font(AmachType.caption)
                            .foregroundStyle(Color.amachDestructive)
                    }
                }
                .padding(AmachSpacing.md)
            }
        }
        .navigationTitle("Shareable Proofs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLabSummaries() }
    }

    // MARK: - Computed Properties

    private var availableMetrics: [ProofableMetric] {
        proofService.availableMetrics(
            labSummary: latestLabSummary,
            dexaSummary: latestDexaSummary
        )
    }

    /// Categories that have at least one metric with data.
    private var availableCategories: [ProofableMetricCategory] {
        let present = Set(availableMetrics.map(\.category))
        return ProofableMetricCategory.allCases.filter { present.contains($0) }
    }

    /// Metrics filtered by the selected category (or all if none selected).
    private var filteredMetrics: [ProofableMetric] {
        guard let cat = selectedCategory else { return availableMetrics }
        return availableMetrics.filter { $0.category == cat }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Prove your health story without sharing raw data.")
                .font(AmachType.h2)
                .foregroundStyle(Color.amachTextPrimary)

            Text("Create signed, on-chain anchored proofs from your Apple Health, bloodwork, and DEXA data.")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
        }
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Choose a category")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AmachSpacing.sm) {
                    ForEach(availableCategories, id: \.rawValue) { category in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if selectedCategory == category {
                                    selectedCategory = nil
                                } else {
                                    selectedCategory = category
                                }
                                selectedMetric = nil
                            }
                        } label: {
                            Text(category.rawValue)
                                .font(AmachType.caption)
                                .foregroundStyle(
                                    selectedCategory == category
                                        ? Color.amachBg
                                        : Color.amachTextPrimary
                                )
                                .padding(.horizontal, AmachSpacing.md)
                                .padding(.vertical, AmachSpacing.sm)
                                .background(
                                    selectedCategory == category
                                        ? Color.amachPrimaryBright
                                        : Color.amachSurface
                                )
                                .cornerRadius(20)
                        }
                    }
                }
            }
        }
    }

    private var metricList: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            Text("Select a metric")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            VStack(spacing: AmachSpacing.sm) {
                ForEach(filteredMetrics) { metric in
                    metricRow(for: metric)
                }
            }
        }
    }

    private func metricRow(for metric: ProofableMetric) -> some View {
        let isSelected = selectedMetric?.id == metric.id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedMetric = metric
                if !metric.supportedPeriods.isEmpty && !metric.supportedPeriods.contains(selectedPeriod) {
                    selectedPeriod = metric.supportedPeriods[0]
                }
            }
        } label: {
            HStack(spacing: AmachSpacing.md) {
                Image(systemName: metric.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.amachPrimaryBright)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(metric.displayName)
                        .font(AmachType.body)
                        .foregroundStyle(Color.amachTextPrimary)
                    Text(metric.subtitle)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.amachPrimaryBright)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
            .padding(AmachSpacing.lg)
            .amachCard()
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.amachPrimaryBright : Color.clear, lineWidth: 1.5)
            )
        }
    }

    private func periodPicker(for metric: ProofableMetric) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Time period")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            HStack(spacing: AmachSpacing.sm) {
                ForEach(metric.supportedPeriods, id: \.self) { period in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedPeriod = period
                        }
                    } label: {
                        Text(period.rawValue)
                            .font(AmachType.caption)
                            .foregroundStyle(
                                selectedPeriod == period
                                    ? Color.amachBg
                                    : Color.amachTextPrimary
                            )
                            .padding(.horizontal, AmachSpacing.lg)
                            .padding(.vertical, AmachSpacing.sm)
                            .background(
                                selectedPeriod == period
                                    ? Color.amachPrimaryBright
                                    : Color.amachSurface
                            )
                            .cornerRadius(16)
                    }
                }
            }
        }
    }

    private var generateButton: some View {
        let isGenerating = generatingMetricId != nil
        return Button {
            guard let metric = selectedMetric else { return }
            Task { await generate(metric) }
        } label: {
            HStack {
                if isGenerating {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "checkmark.shield.fill")
                    Text("Generate Proof")
                }
            }
            .font(AmachType.body)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(AmachSpacing.lg)
            .background(Color.amachPrimaryBright)
            .cornerRadius(12)
        }
        .disabled(isGenerating || !wallet.isConnected)
    }

    // MARK: - Actions

    private func generate(_ metric: ProofableMetric) async {
        guard wallet.isConnected else {
            error = "Connect your wallet to generate proofs."
            return
        }
        generatingMetricId = metric.id
        error = nil
        defer { generatingMetricId = nil }

        do {
            _ = try await proofService.generateProof(
                for: metric,
                period: selectedPeriod,
                labSummary: latestLabSummary,
                dexaSummary: latestDexaSummary
            )
            AmachHaptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadLabSummaries() async {
        isLoadingSummaries = true
        defer { isLoadingSummaries = false }

        guard let context = await HealthContextBuilder.buildLabContext() else {
            latestLabSummary = nil
            latestDexaSummary = nil
            return
        }

        latestLabSummary = context.bloodwork?.first
        latestDexaSummary = context.dexa?.first
    }

    private func recentProofCard(for proof: HealthMetricProofDocument) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Last generated proof")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
            Text(proof.claim.summary)
                .font(AmachType.body)
                .foregroundStyle(Color.amachTextPrimary)
                .lineLimit(3)
            Text(shortHash(proof.evidence.proofHash))
                .font(AmachType.dataMono)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 16 else { return hash }
        return "\(hash.prefix(10))...\(hash.suffix(6))"
    }
}
