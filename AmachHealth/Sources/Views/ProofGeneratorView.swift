// ProofGeneratorView.swift
// AmachHealth
//
// Entry point for creating health metric proofs from the iOS app.

import SwiftUI

// MARK: - Proof Option Model

/// Describes a single proof the user can generate.
/// Add new entries to `ProofGeneratorView.availableProofOptions` to
/// surface additional proof types without touching the rest of the view.
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

    @State private var generatingOptionId: String?
    @State private var error: String?

    @State private var latestLabSummary: LabResultSummary?
    @State private var latestDexaSummary: DexaResultSummary?
    @State private var isLoadingSummaries = true

    @State private var enabledOptionIds: Set<String> = Self.defaultEnabledIds

    /// Default proof options shown on first launch.
    static let defaultEnabledIds: Set<String> = ["hrv_change", "lab_result", "body_composition"]

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                    header

                    proofActionsSection

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

                    customizeSection
                }
                .padding(AmachSpacing.md)
            }
        }
        .navigationTitle("Shareable Proofs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadLabSummaries() }
    }

    // MARK: - Available Proof Options

    /// The full catalogue of proof types. Toggle visibility via `enabledOptionIds`.
    private var allProofOptions: [ProofOption] {
        [
            ProofOption(
                id: "hrv_change",
                title: "HRV change (30 days)",
                subtitle: { "Prove how your recovery has changed over the last month." },
                icon: "waveform.path.ecg",
                isAvailable: { wallet.isConnected },
                generate: {
                    _ = try await proofService.generateMetricChangeProof(metricKey: "heartRateVariabilitySDNN")
                }
            ),
            ProofOption(
                id: "rhr_change",
                title: "Resting heart rate (30 days)",
                subtitle: { "Prove your resting heart rate trend over the last month." },
                icon: "heart.fill",
                isAvailable: { wallet.isConnected },
                generate: {
                    _ = try await proofService.generateMetricChangeProof(metricKey: "restingHeartRate")
                }
            ),
            ProofOption(
                id: "lab_result",
                title: "Latest bloodwork panel",
                subtitle: { labSubtitle },
                icon: "drop.fill",
                isAvailable: { wallet.isConnected && latestLabSummary != nil },
                generate: {
                    guard let lab = latestLabSummary else { return }
                    _ = try await proofService.generateLabResultProof(from: lab)
                }
            ),
            ProofOption(
                id: "body_composition",
                title: "Latest DEXA scan",
                subtitle: { dexaSubtitle },
                icon: "figure.arms.open",
                isAvailable: { wallet.isConnected && latestDexaSummary != nil },
                generate: {
                    guard let dexa = latestDexaSummary else { return }
                    _ = try await proofService.generateBodyCompositionProof(from: dexa)
                }
            ),
            ProofOption(
                id: "step_count",
                title: "Step count (30 days)",
                subtitle: { "Prove your average daily step count over the last month." },
                icon: "figure.walk",
                isAvailable: { wallet.isConnected },
                generate: {
                    _ = try await proofService.generateMetricChangeProof(metricKey: "stepCount")
                }
            ),
            ProofOption(
                id: "sleep_duration",
                title: "Sleep duration (30 days)",
                subtitle: { "Prove your average sleep duration trend." },
                icon: "bed.double.fill",
                isAvailable: { wallet.isConnected },
                generate: {
                    _ = try await proofService.generateMetricChangeProof(metricKey: "sleepAnalysis")
                }
            ),
        ]
    }

    /// Only the options the user has enabled.
    private var visibleProofOptions: [ProofOption] {
        allProofOptions.filter { enabledOptionIds.contains($0.id) }
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

    private var proofActionsSection: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            Text("Generate a proof")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            VStack(spacing: AmachSpacing.sm) {
                ForEach(visibleProofOptions) { option in
                    proofRow(for: option)
                }
            }
        }
    }

    private func proofRow(for option: ProofOption) -> some View {
        let isGenerating = generatingOptionId == option.id
        return Button {
            Task { await generate(option) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title)
                        .font(AmachType.body)
                        .foregroundStyle(Color.amachTextPrimary)
                    Text(option.subtitle())
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
                Spacer()
                if isGenerating {
                    ProgressView()
                        .tint(Color.amachPrimaryBright)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
            .padding(AmachSpacing.lg)
            .amachCard()
        }
        .disabled(isGenerating || !option.isAvailable())
    }

    private var customizeSection: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            Text("Customize proof types")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            Text("Toggle which proofs appear above.")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)

            VStack(spacing: AmachSpacing.sm) {
                ForEach(allProofOptions) { option in
                    HStack(spacing: AmachSpacing.md) {
                        Image(systemName: option.icon)
                            .font(.system(size: 16))
                            .foregroundStyle(Color.amachPrimaryBright)
                            .frame(width: 24)

                        Text(option.title)
                            .font(AmachType.body)
                            .foregroundStyle(Color.amachTextPrimary)

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { enabledOptionIds.contains(option.id) },
                            set: { enabled in
                                if enabled {
                                    enabledOptionIds.insert(option.id)
                                } else {
                                    enabledOptionIds.remove(option.id)
                                }
                            }
                        ))
                        .labelsHidden()
                        .tint(Color.amachPrimaryBright)
                    }
                    .padding(.vertical, AmachSpacing.xs)
                }
            }
            .padding(AmachSpacing.lg)
            .amachCard()
        }
    }

    // MARK: - Subtitles

    private var labSubtitle: String {
        if isLoadingSummaries { return "Loading latest bloodwork..." }
        if let lab = latestLabSummary { return "Most recent panel on \(lab.date)" }
        return "No bloodwork records found yet."
    }

    private var dexaSubtitle: String {
        if isLoadingSummaries { return "Loading latest DEXA..." }
        if let dexa = latestDexaSummary { return "Most recent scan on \(dexa.date)" }
        return "No DEXA records found yet."
    }

    // MARK: - Actions

    private func generate(_ option: ProofOption) async {
        guard wallet.isConnected else {
            error = "Connect your wallet to generate proofs."
            return
        }
        generatingOptionId = option.id
        error = nil
        defer { generatingOptionId = nil }

        do {
            try await option.generate()
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
