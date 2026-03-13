// ProofDetailView.swift
// AmachHealth
//
// Read-only view for inspecting a generated HealthMetricProofDocument.

import SwiftUI

struct ProofDetailView: View {
    let proof: HealthMetricProofDocument

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                    headerCard
                    proverCard
                    evidenceCard
                    metadataCard
                }
                .padding(AmachSpacing.md)
            }
        }
        .navigationTitle("Proof Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text(proof.claim.summary)
                .font(AmachType.h2)
                .foregroundStyle(Color.amachTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(proof.claim.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)

            Text(shortHash(proof.evidence.proofHash))
                .font(AmachType.dataMono)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private var proverCard: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Prover")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            VStack(alignment: .leading, spacing: 4) {
                row("Wallet", shortHash(proof.prover.walletAddress))
                if let contract = proof.prover.contractAddress {
                    row("Contract", shortHash(contract))
                }
                if let uid = proof.prover.attestationUid {
                    row("Attestation UID", shortHash(uid))
                }
                if let tx = proof.prover.attestationTxHash {
                    row("Attestation Tx", shortHash(tx))
                }
                row("Chain ID", String(proof.prover.chainId))
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private var evidenceCard: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Evidence")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            VStack(alignment: .leading, spacing: 4) {
                if let dataHash = proof.evidence.dataContentHash {
                    row("Data hash", shortHash(dataHash))
                }
                row("Proof hash", shortHash(proof.evidence.proofHash))
                if let tx = proof.evidence.attestationTxHash {
                    row("Attestation Tx", shortHash(tx))
                }
                if let uri = proof.evidence.storjUri {
                    row("Storj URI", uri)
                }
                if let dataType = proof.evidence.dataType {
                    row("Data type", dataType)
                }
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Metadata")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            VStack(alignment: .leading, spacing: 4) {
                row("Created", proof.metadata.createdAt)
                row("Platform", proof.metadata.platform)
                if let version = proof.metadata.appVersion {
                    row("App version", version)
                }
                if let generator = proof.metadata.generator {
                    row("Generator", generator)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Signature")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
                Text(shortHash(proof.signature))
                    .font(AmachType.dataMono)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            .padding(.top, AmachSpacing.sm)
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
            Spacer()
            Text(value)
                .font(AmachType.dataMono)
                .foregroundStyle(Color.amachTextPrimary)
        }
    }

    private func shortHash(_ value: String) -> String {
        guard value.count > 16 else { return value }
        return "\(value.prefix(10))…\(value.suffix(6))"
    }
}

