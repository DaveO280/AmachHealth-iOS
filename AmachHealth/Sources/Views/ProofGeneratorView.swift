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
    @State private var baselineWeekStart: Date = Calendar.current.date(byAdding: .day, value: -168, to: Date()) ?? Date()
    @State private var baselineWeekEnd: Date = Calendar.current.date(byAdding: .day, value: -140, to: Date()) ?? Date()
    @State private var comparisonWeekStart: Date = Calendar.current.date(byAdding: .day, value: -35, to: Date()) ?? Date()
    @State private var comparisonWeekEnd: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

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

                    metricSelector

                    if let metric = selectedMetric, !metric.supportedPeriods.isEmpty {
                        periodPicker(for: metric)
                    }

                    if let metric = selectedMetric, shouldShowWeeklyComparison(for: metric) {
                        weeklyRangePicker
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

    private var metricSelector: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            Text("Metric")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            Menu {
                ForEach(filteredMetrics) { metric in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedMetric = metric
                            if !metric.supportedPeriods.isEmpty && !metric.supportedPeriods.contains(selectedPeriod) {
                                selectedPeriod = metric.supportedPeriods[0]
                            }
                        }
                    } label: {
                        Label(metric.displayName, systemImage: metric.icon)
                    }
                }
            } label: {
                HStack(spacing: AmachSpacing.md) {
                    Image(systemName: selectedMetric?.icon ?? "slider.horizontal.3")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.amachPrimaryBright)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedMetric?.displayName ?? "Select a metric")
                            .font(AmachType.body)
                            .foregroundStyle(Color.amachTextPrimary)
                        Text(selectedMetric?.subtitle ?? "Choose what to prove")
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextSecondary)
                    }

                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundStyle(Color.amachTextSecondary)
                }
                .padding(AmachSpacing.lg)
                .amachCard()
            }
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

    private var weeklyRangePicker: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Comparison windows")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            VStack(spacing: AmachSpacing.sm) {
                Text("Baseline window")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                DatePicker("Baseline start", selection: $baselineWeekStart, displayedComponents: [.date])
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
                    .tint(Color.amachPrimaryBright)

                DatePicker("Baseline end", selection: $baselineWeekEnd, in: baselineWeekStart..., displayedComponents: [.date])
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
                    .tint(Color.amachPrimaryBright)

                Divider()

                Text("Comparison window")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                DatePicker("Comparison start", selection: $comparisonWeekStart, displayedComponents: [.date])
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
                    .tint(Color.amachPrimaryBright)

                DatePicker("Comparison end", selection: $comparisonWeekEnd, in: comparisonWeekStart..., displayedComponents: [.date])
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
                    .tint(Color.amachPrimaryBright)

                Text("Verifies baseline average window vs comparison average window.")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            .padding(AmachSpacing.md)
            .amachCard()
        }
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
            let iso = ISO8601DateFormatter()
            let comparison = shouldShowWeeklyComparison(for: metric)
                ? ProofComparisonOptions(
                    baselineStartISO: iso.string(from: startOfWeek(baselineWeekStart)),
                    baselineEndISO: iso.string(from: startOfWeek(baselineWeekEnd)),
                    comparisonStartISO: iso.string(from: startOfWeek(comparisonWeekStart)),
                    comparisonEndISO: iso.string(from: startOfWeek(comparisonWeekEnd))
                )
                : .default

            _ = try await proofService.generateProof(
                for: metric,
                period: selectedPeriod,
                comparison: comparison,
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

    private func shouldShowWeeklyComparison(for metric: ProofableMetric) -> Bool {
        metric.category == .healthKit && metric.proofType == .metricChange
    }

    private func startOfWeek(_ date: Date) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? date
    }
}
