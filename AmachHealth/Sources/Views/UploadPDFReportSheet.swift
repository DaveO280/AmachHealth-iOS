// UploadPDFReportSheet.swift
// AmachHealth
//
// Sheet for importing a PDF report (bloodwork or DEXA scan) from the Files app
// and uploading it to Storj as a FHIR-formatted health record.

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
            }

            Text("Your PDF is encrypted and stored privately on Storj under your wallet address.")
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
                        Label(detected, systemImage: detected == "DEXA Scan" ? "figure.stand" : "drop.fill")
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

    private var uploadButton: some View {
        Button {
            Task { await performUpload() }
        } label: {
            Text("Upload to Storj")
        }
        .amachPrimaryButtonStyle(isLoading: isUploading)
        .disabled(isUploading || selectedFileData == nil || wallet.encryptionKey == nil)
    }

    @ViewBuilder
    private var stateView: some View {
        switch uploadService.state {
        case .idle:
            EmptyView()
        case .extracting:
            progressRow(label: "Reading PDF…", icon: "doc.text.magnifyingglass")
        case .parsing:
            progressRow(label: "Analyzing health data…", icon: "stethoscope")
        case .uploading(let progress):
            VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                progressRow(label: "Uploading to Storj…", icon: "icloud.and.arrow.up")
                ProgressView(value: progress)
                    .tint(Color.amachPrimaryBright)
            }
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
                Text(result.wasDuplicate ? "Already uploaded" : "Upload complete")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachSuccess)
            }

            Text("Report ID: \(result.reportId)")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)

            Text(result.storjUri)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
                .lineLimit(2)

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

    private var isUploading: Bool {
        switch uploadService.state {
        case .extracting, .parsing, .uploading: return true
        default: return false
        }
    }

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

    private func detectReportType(data: Data, filename: String) -> String? {
        guard let report = PDFReportParser.parse(pdfData: data, filename: filename) else { return nil }
        switch report {
        case .bloodwork: return "Bloodwork"
        case .dexa: return "DEXA Scan"
        }
    }

    private func performUpload() async {
        guard let data = selectedFileData,
              let filename = selectedFileName,
              let encryptionKey = wallet.encryptionKey else {
            errorMessage = "Connect your wallet before uploading."
            return
        }

        errorMessage = nil
        do {
            _ = try await uploadService.upload(
                pdfData: data,
                filename: filename,
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey
            )
            AmachHaptics.success()
        } catch {
            uploadService.state = .error(error.localizedDescription)
            AmachHaptics.error()
        }
    }
}
