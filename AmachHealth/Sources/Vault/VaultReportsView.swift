// VaultReportsView.swift
// AmachHealth
//
// Sync → Lab & Records → Manage: every report in the vault, grouped by kind,
// with delete (swipe, long-press, or from the report itself). Deleting
// removes the report, its values and its original PDF from this phone, and
// from the encrypted backup at its next run.

import SwiftUI

@MainActor
enum VaultReportActions {
    enum DeleteError: LocalizedError {
        case noVault
        var errorDescription: String? { "Connect your wallet to manage reports on this phone." }
    }

    /// Delete a report and refresh what depends on it (Luma's lab context).
    static func delete(reportId: String) throws {
        guard let vault = LocalVault.shared.database else { throw DeleteError.noVault }
        try vault.deleteLabReport(id: reportId)
        LabContextService.shared.invalidate()
    }

    static let deleteExplanation =
        "This removes the report, its values and its original PDF from this phone. " +
        "Luma will no longer see it. If encrypted backup is on, it's removed from your backup at the next backup."
}

struct VaultReportsView: View {
    var onChange: () async -> Void = {}

    @ObservedObject private var vault = LocalVault.shared
    @State private var reports: [LabReportWithMarkers] = []
    @State private var pendingDelete: LabReportWithMarkers?
    @State private var errorMessage: String?

    private var groups: [(title: String, items: [LabReportWithMarkers])] {
        [
            ("Bloodwork", reports.filter { $0.report.kindValue == .bloodwork }),
            ("DEXA scans", reports.filter { $0.report.kindValue == .dexa }),
            ("Medical documents", reports.filter { $0.report.kindValue == .medical }),
        ].filter { !$0.items.isEmpty }
    }

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()
            List {
                if reports.isEmpty {
                    Text("No reports in your vault.")
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                        .listRowBackground(Color.amachSurface)
                }
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.items) { report in
                            row(report)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { pendingDelete = report } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) { pendingDelete = report } label: {
                                        Label("Delete report", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        Text("\(group.title.uppercased()) · \(group.items.count)")
                            .font(AmachType.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.amachTextSecondary)
                            .tracking(1)
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachDestructive)
                        .listRowBackground(Color.amachSurface)
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("Swipe left on a report, or press and hold, to delete it. " + VaultReportActions.deleteExplanation)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Manage reports")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete this report?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { report in
            Button("Delete \(report.displayTitle)", role: .destructive) { delete(report) }
            Button("Cancel", role: .cancel) {}
        } message: { report in
            Text("\(Self.dateText(report)). " + VaultReportActions.deleteExplanation)
        }
        .task(id: vault.isOpen) { reload() }
    }

    private func row(_ report: LabReportWithMarkers) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(report.displayTitle)
                    .font(AmachType.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.amachTextPrimary)
                    .lineLimit(2)
                Spacer()
                Text(Self.dateText(report))
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            Text(details(report))
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .listRowBackground(Color.amachSurface)
    }

    private func details(_ report: LabReportWithMarkers) -> String {
        var parts = ["\(report.markers.count) values"]
        if let lab = report.report.laboratory, !lab.isEmpty { parts.insert(lab, at: 0) }
        if vault.database?.hasOriginalPdf(reportId: report.id) == true { parts.append("original PDF kept") }
        return parts.joined(separator: " · ")
    }

    static func dateText(_ report: LabReportWithMarkers) -> String {
        report.report.reportDate ?? Date(unixMillis: report.report.createdAt).vaultDay
    }

    private func reload() {
        reports = (try? vault.database?.labReports()) ?? []
    }

    private func delete(_ report: LabReportWithMarkers) {
        do {
            try VaultReportActions.delete(reportId: report.id)
            errorMessage = nil
            AmachHaptics.success()
            reload()
            Task { await onChange() }
        } catch {
            errorMessage = "Couldn't delete: \(error.localizedDescription)"
            AmachHaptics.error()
        }
    }
}
