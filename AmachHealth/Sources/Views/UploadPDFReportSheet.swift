// UploadPDFReportSheet.swift
// AmachHealth
//
// Sheet for importing a PDF report (bloodwork, DEXA, other medical documents)
// from the Files app. The private AI reads it, the user reviews what was
// found, and only then is it saved in the vault on this phone.

import SwiftUI
import UniformTypeIdentifiers

struct UploadPDFReportSheet: View {
    let onUploaded: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var wallet: WalletService
    @StateObject private var uploadService = PDFUploadService.shared

    @State private var isPickerPresented = false
    @State private var selectedFileName: String?
    @State private var selectedFileData: Data?
    @State private var detectedType: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                        instructionCard

                        if let fileName = selectedFileName {
                            selectedFileCard(fileName: fileName)
                        } else {
                            pickButton
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(AmachType.caption)
                                .foregroundStyle(Color.amachDestructive)
                                .padding(.horizontal, AmachSpacing.md)
                        }

                        if selectedFileData != nil {
                            uploadButton
                        }

                        stateView
                    }
                    .padding(AmachSpacing.md)
                }
            }
            .navigationTitle("Import PDF Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.amachPrimaryBright)
                        .disabled(isUploading)
                }
            }
        }
        .fileImporter(
            isPresented: $isPickerPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            handlePickerResult(result)
        }
        .presentationDetents([.large])
    }

    // MARK: - Sub-views

    private var instructionCard: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Supported Reports")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Label("Bloodwork (Quest, LabCorp, etc.)", systemImage: "drop.fill")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
                Label("DEXA body composition scans", systemImage: "figure.stand")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
                Label("Gut health (Tiny Health)", systemImage: "leaf")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
                Label("Medical records & other documents", systemImage: "doc.text")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            Text("A private AI model reads your report, you check what it found, then it's saved on this phone. Long lab reports take about 3 minutes.")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private var pickButton: some View {
        Button {
            isPickerPresented = true
        } label: {
            HStack(spacing: AmachSpacing.sm) {
                Image(systemName: "doc.badge.plus")
                    .font(.title3)
                Text("Choose PDF from Files")
            }
            .frame(maxWidth: .infinity)
        }
        .amachSecondaryButtonStyle()
    }

    private func selectedFileCard(fileName: String) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundStyle(Color.amachPrimaryBright)
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextPrimary)
                        .lineLimit(2)
                    if let detected = detectedType {
                        Label(detected, systemImage: iconForReportType(detected))
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachSuccess)
                    } else {
                        Text("Detecting report type…")
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                }
                Spacer()
                Button {
                    selectedFileName = nil
                    selectedFileData = nil
                    detectedType = nil
                    errorMessage = nil
                    uploadService.reset()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.amachTextSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isUploading)
            }
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    @ViewBuilder
    private var uploadButton: some View {
        if case .idle = uploadService.state {
            Button {
                Task { await performRead() }
            } label: {
                Text("Read report")
            }
            .amachPrimaryButtonStyle(isLoading: isUploading)
            .disabled(isUploading || selectedFileData == nil || !LocalVault.shared.isOpen)
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch uploadService.state {
        case .idle:
            EmptyView()
        case .extracting:
            progressRow(label: "Reading the PDF…", icon: "doc.text.magnifyingglass")
        case .parsing(let since):
            VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                SwiftUI.TimelineView(.periodic(from: since, by: 1)) { context in
                    progressRow(
                        label: "Private AI is reading your report… \(Self.clock(context.date.timeIntervalSince(since)))",
                        icon: "sparkles"
                    )
                }
                Text("Long lab reports take about 3 minutes. Keep Amach open until it's done.")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
                    .padding(.horizontal, AmachSpacing.md)
            }
        case .aiFailed(let message):
            aiFailedCard(message)
        case .review(let result):
            PDFReportReviewCard(
                result: result,
                onSave: {
                    uploadService.save(result)
                    if case .done = uploadService.state { AmachHaptics.success() } else { AmachHaptics.error() }
                },
                onDiscard: { uploadService.reset() },
                onTryAI: { Task { await performRead() } }
            )
        case .saving:
            progressRow(label: "Saving to your vault…", icon: "lock.shield")
        case .done(let result):
            uploadSuccessCard(result: result)
        case .error(let message):
            Text(message)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachDestructive)
                .padding(AmachSpacing.md)
                .amachCard()
        }
    }

    private func aiFailedCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachWarning)
            Button("Try again") { Task { await performRead() } }
                .amachPrimaryButtonStyle()
            Button("Use the offline reader") { Task { await performOfflineRead() } }
                .amachSecondaryButtonStyle()
            Text("The offline reader is instant but can miss values on unusual layouts. You'll see what it found before anything is saved.")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func progressRow(label: String, icon: String) -> some View {
        HStack(spacing: AmachSpacing.sm) {
            ProgressView()
                .tint(Color.amachPrimaryBright)
                .scaleEffect(0.85)
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color.amachPrimaryBright)
            Text(label)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    private func uploadSuccessCard(result: PDFUploadResult) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack {
                Image(systemName: result.wasDuplicate ? "checkmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(Color.amachSuccess)
                Text(result.wasDuplicate ? "Already in your vault" : "Saved to your vault")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachSuccess)
            }

            Text("Report ID: \(result.reportId)")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)

            Button {
                Task {
                    await onUploaded()
                    dismiss()
                }
            } label: {
                Text("Done")
            }
            .amachPrimaryButtonStyle()
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    // MARK: - Logic

    private var isUploading: Bool { uploadService.state.isWorking }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        errorMessage = nil
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                selectedFileData = data
                selectedFileName = url.lastPathComponent

                // Quick type detection (off main thread)
                Task.detached(priority: .userInitiated) {
                    let detected = await detectReportType(data: data, filename: url.lastPathComponent)
                    await MainActor.run { self.detectedType = detected }
                }
            } catch {
                errorMessage = "Could not read the file: \(error.localizedDescription)"
            }
        }
    }

    private func iconForReportType(_ type: String) -> String {
        switch type {
        case "DEXA Scan": return "figure.stand"
        case "Bloodwork": return "drop.fill"
        case "Medical Record": return "doc.text"
        default: return "doc.fill"
        }
    }

    private func detectReportType(data: Data, filename: String) -> String? {
        guard let report = PDFReportParser.parse(pdfData: data, filename: filename) else { return nil }
        switch report {
        case .bloodwork: return "Bloodwork"
        case .dexa: return "DEXA Scan"
        case .medicalRecord: return "Medical Record"
        case .gutHealth: return "Gut Health"
        }
    }

    private func performRead() async {
        guard let data = selectedFileData, let filename = selectedFileName, LocalVault.shared.isOpen else {
            errorMessage = "Connect your wallet before importing."
            return
        }
        errorMessage = nil
        // A long read shouldn't be cut off by auto-lock.
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        await uploadService.read(pdfData: data, filename: filename)
        if case .aiFailed = uploadService.state { AmachHaptics.error() }
    }

    private func performOfflineRead() async {
        guard let data = selectedFileData, let filename = selectedFileName else { return }
        await uploadService.readOffline(pdfData: data, filename: filename)
    }
}
