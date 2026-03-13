// ProofGeneratorView.swift
// AmachHealth
//
// Entry point for creating health metric proofs from the iOS app.

import SwiftUI

struct ProofGeneratorView: View {
    @EnvironmentObject private var wallet: WalletService
    @StateObject private var proofService = HealthMetricProofService.shared

    @State private var isGeneratingMetricChange = false
    @State private var isGeneratingLabProof = false
    @State private var isGeneratingDexaProof = false
    @State private var error: String?

    @State private var latestLabSummary: LabResultSummary?
    @State private var latestDexaSummary: DexaResultSummary?
    @State private var isLoadingSummaries = true

    var body: some View {
        NavigationStack {
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
                    }
                    .padding(AmachSpacing.md)
                }
            }
            .navigationTitle("Shareable Proofs")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await loadLabSummaries() }
    }

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
                Button {
                    Task { await generateMetricChange() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("HRV change (30 days)")
                                .font(AmachType.body)
                                .foregroundStyle(Color.amachTextPrimary)
                            Text("Prove how your recovery has changed over the last month.")
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.amachTextSecondary)
                        }
                        Spacer()
                        if isGeneratingMetricChange {
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
                .disabled(isGeneratingMetricChange || !wallet.isConnected)

                Button {
                    Task { await generateLabProof() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latest bloodwork panel")
                                .font(AmachType.body)
                                .foregroundStyle(Color.amachTextPrimary)
                            Text(labSubtitle)
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.amachTextSecondary)
                        }
                        Spacer()
                        if isGeneratingLabProof {
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
                .disabled(isGeneratingLabProof || latestLabSummary == nil || !wallet.isConnected)

                Button {
                    Task { await generateDexaProof() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Latest DEXA scan")
                                .font(AmachType.body)
                                .foregroundStyle(Color.amachTextPrimary)
                            Text(dexaSubtitle)
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.amachTextSecondary)
                        }
                        Spacer()
                        if isGeneratingDexaProof {
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
                .disabled(isGeneratingDexaProof || latestDexaSummary == nil || !wallet.isConnected)
            }
        }
    }

    private var labSubtitle: String {
        if isLoadingSummaries {
            return "Loading latest bloodwork…"
        }
        if let lab = latestLabSummary {
            return "Most recent panel on \(lab.date)"
        }
        return "No bloodwork records found yet."
    }

    private var dexaSubtitle: String {
        if isLoadingSummaries {
            return "Loading latest DEXA…"
        }
        if let dexa = latestDexaSummary {
            return "Most recent scan on \(dexa.date)"
        }
        return "No DEXA records found yet."
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

    private func generateMetricChange() async {
        guard wallet.isConnected else {
            error = "Connect your wallet to generate proofs."
            return
        }
        isGeneratingMetricChange = true
        error = nil
        defer { isGeneratingMetricChange = false }

        do {
            _ = try await proofService.generateMetricChangeProof(metricKey: "heartRateVariabilitySDNN")
            AmachHaptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func generateLabProof() async {
        guard wallet.isConnected else {
            error = "Connect your wallet to generate proofs."
            return
        }
        guard let latestLabSummary else {
            error = "No bloodwork records available."
            return
        }

        isGeneratingLabProof = true
        error = nil
        defer { isGeneratingLabProof = false }

        do {
            _ = try await proofService.generateLabResultProof(from: latestLabSummary)
            AmachHaptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func generateDexaProof() async {
        guard wallet.isConnected else {
            error = "Connect your wallet to generate proofs."
            return
        }
        guard let latestDexaSummary else {
            error = "No DEXA records available."
            return
        }

        isGeneratingDexaProof = true
        error = nil
        defer { isGeneratingDexaProof = false }

        do {
            _ = try await proofService.generateBodyCompositionProof(from: latestDexaSummary)
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

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 16 else { return hash }
        return "\(hash.prefix(10))…\(hash.suffix(6))"
    }
}

