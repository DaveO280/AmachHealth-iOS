// VaultViews.swift
// AmachHealth
//
// Vault status on the Health Sync screen (HealthKit history backfill,
// Storj import counts and failures) and the lab report card.

import SwiftUI

struct VaultStatusSection: View {
    @ObservedObject private var vault = LocalVault.shared
    @ObservedObject private var ingestion = HealthKitIngestionService.shared
    @ObservedObject private var importer = StorjImportService.shared
    @ObservedObject private var wallet = WalletService.shared
    @ObservedObject private var backup = BackupService.shared
    @State private var showFailures = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(Color.amachPrimaryBright)
                Text("On-device vault")
                    .font(.headline)
                    .foregroundStyle(Color.amachTextPrimary)
                Spacer()
            }

            backfillRow
            Divider().overlay(Color.amachPrimary.opacity(0.15))
            importRows

            Divider().overlay(Color.amachPrimary.opacity(0.15))
            HStack {
                Text("Encrypted backup")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.amachTextPrimary)
                Spacer()
                Text(EncryptedBackupSection.statusLine(backup))
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .padding(16)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1))
        .sheet(isPresented: $showFailures) { failuresSheet }
    }

    // MARK: - HealthKit backfill

    @ViewBuilder
    private var backfillRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Apple Health history")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.amachTextPrimary)
            if let progress = ingestion.backfill, progress.isRunning {
                ProgressView(value: progress.fraction)
                    .tint(Color.amachPrimaryBright)
                Text("Reading history… back to \(progress.oldestDayDone ?? "today")")
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            } else if let range = try? vault.database?.dailyMetricDayRange() {
                Text("\(range.first) → \(range.last)")
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            } else {
                Text("No days stored yet")
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            if let error = ingestion.lastError {
                Text("Last write failed: \(error)")
                    .font(.caption)
                    .foregroundStyle(Color.amachWarning)
            }
        }
    }

    // MARK: - Storj import

    @ViewBuilder
    private var importRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import from Storj")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.amachTextPrimary)

            switch importer.state {
            case .running(let done, let total):
                ProgressView(value: total == 0 ? 0 : Double(done) / Double(total))
                    .tint(Color.amachPrimaryBright)
                Text(total == 0 ? "Listing your files…" : "Decrypting on this phone… \(done) of \(total)")
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            case .failed(let message):
                Text("Import couldn't run: \(message)")
                    .font(.caption)
                    .foregroundStyle(Color.amachDestructive)
                retryButton
            default:
                if let report = importer.lastReport {
                    reportSummary(report)
                } else {
                    Text("Not run yet")
                        .font(.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                    retryButton
                }
            }
        }
    }

    private func reportSummary(_ report: ImportReport) -> some View {
        let t = report.vaultTotals
        let lines: [(String, Int)] = [
            ("Files listed", report.objectsListed),
            ("Imported", report.imported + report.previouslyImported),
            ("Duplicates", report.duplicates),
            ("Kept as JSON", report.archived),
            ("Days of health data", report.counts["health_days"] ?? 0),
            ("Lab reports", t.labReports),
            ("Timeline events", t.timelineEvents),
            ("Chat sessions", t.chatSessions),
            ("Chat messages", t.chatMessages),
            ("Memory facts", t.memoryFacts),
        ]
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.0) { line in
                HStack {
                    Text(line.0).font(.caption).foregroundStyle(Color.amachTextSecondary)
                    Spacer()
                    Text("\(line.1)").font(AmachType.dataMono).foregroundStyle(Color.amachTextPrimary)
                }
            }
            if !report.failures.isEmpty {
                Button {
                    showFailures = true
                } label: {
                    Label("\(report.failures.count) failed — see why", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.amachWarning)
                }
                retryButton
            }
            if !report.notes.isEmpty {
                Text(report.notes.prefix(3).joined(separator: "\n"))
                    .font(.caption2)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
    }

    private var retryButton: some View {
        Button("Run import") {
            guard let database = vault.database, let key = vault.walletKey ?? wallet.encryptionKey else { return }
            importer.run(vault: database, walletKey: key)
        }
        .font(.caption.weight(.semibold))
    }

    private var failuresSheet: some View {
        NavigationStack {
            List(importer.lastReport?.failures ?? []) { failure in
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.dataType).font(.subheadline.weight(.semibold))
                    Text(failure.reason).font(.caption)
                    Text(failure.key).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Import failures")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct VaultLabReportCard: View {
    let report: LabReportWithMarkers

    private var isDexa: Bool { report.report.kindValue == .dexa }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: isDexa ? "figure.stand" : (report.report.kindValue == .medical ? "doc.text" : "drop.fill"))
                        .font(.system(size: 13))
                        .foregroundStyle(isDexa ? Color.amachAccent : Color.amachPrimaryBright)
                        .frame(width: 26, height: 26)
                        .background((isDexa ? Color.amachAccent : Color.amachPrimary).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 7))

                    Text(report.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.amachTextPrimary)
                }
                Spacer()
                Text(report.report.reportDate ?? Date(unixMillis: report.report.createdAt).vaultDay)
                    .font(.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            let summaries = report.summaryLines
            Text(summaries.isEmpty ? "\(report.markers.count) values" : summaries.joined(separator: "  •  "))
                .font(.caption)
                .foregroundStyle(Color.amachTextSecondary)
                .multilineTextAlignment(.leading)

            if report.report.attestationTxHash != nil {
                Label("Verified on ZKsync", systemImage: "checkmark.seal.fill")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachSuccess)
            }
        }
        .padding(14)
        .background(Color.amachBg.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.amachPrimary.opacity(0.08), lineWidth: 1))
    }
}
