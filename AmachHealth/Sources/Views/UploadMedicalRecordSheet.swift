// UploadMedicalRecordSheet.swift
// AmachHealth
//
// Sheet for uploading an arbitrary medical record (PDF, JPEG, PNG, HEIC).
//
// Upload flow:
//   1. File picker  — PDF / JPEG / PNG / HEIC
//   2. Category picker — required, no default (blocks submit)
//   3. Record date  — required (the date the record is *about*), blocks submit
//   4. Provider name — optional
//   5. Notes        — optional
//   6. Upload button → MedicalRecordUploadService
//
// Lane A (Bloodwork / DEXA Scan) routes through the existing structured parser.
// Lane B (everything else) stores the blob + metadata and creates a timeline event.

import SwiftUI
import UniformTypeIdentifiers

struct UploadMedicalRecordSheet: View {
    let onUploaded: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var wallet: WalletService
    @StateObject private var uploadService = MedicalRecordUploadService.shared

    // File picker state
    @State private var isPickerPresented  = false
    @State private var selectedFileName: String?
    @State private var selectedFileData: Data?

    // Form state
    @State private var selectedCategory: MedicalRecordCategory?
    @State private var recordDate = Date()
    @State private var providerName = ""
    @State private var notes = ""
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        selectedFileData != nil
            && selectedCategory != nil
            && !isUploading
            && wallet.encryptionKey != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                        // File picker section
                        fileSection

                        // Category picker (required)
                        categorySection

                        // Record date (required)
                        recordDateSection

                        // Optional fields
                        optionalSection

                        // Validation / wallet hint
                        if let errorMessage {
                            Text(errorMessage)
                                .font(AmachType.caption)
                                .foregroundStyle(Color.amachDestructive)
                                .padding(.horizontal, AmachSpacing.md)
                        } else if wallet.encryptionKey == nil {
                            Text("Connect your wallet to upload records.")
                                .font(AmachType.caption)
                                .foregroundStyle(Color.amachTextSecondary)
                                .padding(.horizontal, AmachSpacing.md)
                        }

                        // Upload button
                        if selectedFileData != nil {
                            uploadButton
                        }

                        // Progress / result
                        stateView
                    }
                    .padding(AmachSpacing.md)
                }
            }
            .navigationTitle("Upload Medical Record")
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
            allowedContentTypes: [.pdf, .jpeg, .png, .heic],
            allowsMultipleSelection: false
        ) { result in
            handlePickerResult(result)
        }
        .presentationDetents([.large])
    }

    // MARK: - File section

    private var fileSection: some View {
        Group {
            if let fileName = selectedFileName {
                selectedFileCard(fileName: fileName)
            } else {
                pickButton
            }
        }
    }

    private var pickButton: some View {
        Button { isPickerPresented = true } label: {
            HStack(spacing: AmachSpacing.sm) {
                Image(systemName: "doc.badge.plus")
                    .font(.title3)
                Text("Choose File")
            }
            .frame(maxWidth: .infinity)
        }
        .amachSecondaryButtonStyle()
    }

    private func selectedFileCard(fileName: String) -> some View {
        HStack {
            Image(systemName: "doc.fill")
                .foregroundStyle(Color.amachPrimaryBright)
            VStack(alignment: .leading, spacing: 2) {
                Text(fileName)
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
                    .lineLimit(2)
                if let cat = selectedCategory {
                    Label(cat.displayName, systemImage: cat.icon)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
            Spacer()
            if !isUploading {
                Button {
                    clearFile()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.amachTextSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    // MARK: - Category section

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack {
                Text("Record Type")
                    .font(AmachType.h3)
                    .foregroundStyle(Color.amachTextPrimary)
                Text("Required")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachDestructive)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.amachDestructive.opacity(0.12))
                    .clipShape(Capsule())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: AmachSpacing.sm) {
                ForEach(MedicalRecordCategory.allCases) { category in
                    categoryChip(category)
                }
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func categoryChip(_ category: MedicalRecordCategory) -> some View {
        let isSelected = selectedCategory == category
        return Button {
            AmachHaptics.toggle()
            selectedCategory = category
        } label: {
            HStack(spacing: AmachSpacing.xs) {
                Image(systemName: category.icon)
                    .font(.caption2)
                Text(category.displayName)
                    .font(AmachType.tiny)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, AmachSpacing.sm)
            .padding(.vertical, AmachSpacing.xs)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
                isSelected
                    ? Color.amachPrimary.opacity(0.15)
                    : Color.amachSurface
            )
            .foregroundStyle(
                isSelected
                    ? Color.amachPrimaryBright
                    : Color.amachTextSecondary
            )
            .overlay(
                RoundedRectangle(cornerRadius: AmachRadius.sm)
                    .stroke(
                        isSelected ? Color.amachPrimaryBright : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Record date section

    private var recordDateSection: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack {
                Text("Record Date")
                    .font(AmachType.h3)
                    .foregroundStyle(Color.amachTextPrimary)
                Text("Required")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachDestructive)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.amachDestructive.opacity(0.12))
                    .clipShape(Capsule())
            }
            Text("The date this record is from (not today's upload date).")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)

            DatePicker(
                "Record date",
                selection: $recordDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(Color.amachPrimaryBright)
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    // MARK: - Optional fields

    private var optionalSection: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            Text("Additional Details")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            VStack(alignment: .leading, spacing: AmachSpacing.xs) {
                Text("Provider / Lab")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
                TextField("e.g. Dr. Smith or Quest Diagnostics", text: $providerName)
                    .font(AmachType.body)
                    .foregroundStyle(Color.amachTextPrimary)
                    .padding(AmachSpacing.sm)
                    .background(Color.amachSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
            }

            VStack(alignment: .leading, spacing: AmachSpacing.xs) {
                Text("Notes")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
                TextField("Optional context or observations", text: $notes, axis: .vertical)
                    .font(AmachType.body)
                    .foregroundStyle(Color.amachTextPrimary)
                    .lineLimit(3...6)
                    .padding(AmachSpacing.sm)
                    .background(Color.amachSurface)
                    .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    // MARK: - Upload button

    private var uploadButton: some View {
        Button {
            Task { await performUpload() }
        } label: {
            if selectedCategory?.isLaneA == true {
                Text("Upload & Analyze")
            } else {
                Text("Upload to Storj")
            }
        }
        .amachPrimaryButtonStyle(isLoading: isUploading)
        .disabled(!canSubmit)
    }

    // MARK: - State view

    @ViewBuilder
    private var stateView: some View {
        switch uploadService.state {
        case .idle:
            EmptyView()
        case .uploading(let progress):
            uploadingCard(progress: progress)
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

    private func uploadingCard(progress: Double) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack(spacing: AmachSpacing.sm) {
                ProgressView()
                    .tint(Color.amachPrimaryBright)
                    .scaleEffect(0.85)
                Text(uploadStatusLabel(progress: progress))
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            ProgressView(value: progress)
                .tint(Color.amachPrimaryBright)
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    private func uploadStatusLabel(progress: Double) -> String {
        switch progress {
        case ..<0.2: return "Uploading file…"
        case ..<0.5: return selectedCategory?.isLaneA == true ? "Analyzing record…" : "Uploading…"
        case ..<0.8: return "Writing metadata…"
        default:     return "Finalizing…"
        }
    }

    private func uploadSuccessCard(result: MedicalRecordUploadResult) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.amachSuccess)
                Text("Upload complete")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachSuccess)
            }

            if result.metadata.category.isLaneA {
                laneAParserResultRow(metadata: result.metadata)
            }

            Text("Record ID: \(result.metadata.id.prefix(8))…")
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

    @ViewBuilder
    private func laneAParserResultRow(metadata: MedicalRecordMetadata) -> some View {
        switch metadata.parserStatus {
        case .succeeded:
            Label("Data extracted successfully", systemImage: "checkmark.seal.fill")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachSuccess)
        case .failed:
            Label("Auto-extraction failed — saved as document", systemImage: "exclamationmark.triangle")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachWarning)
        case .skipped:
            Label("Extraction skipped (non-PDF)", systemImage: "info.circle")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Logic

    private var isUploading: Bool {
        if case .uploading = uploadService.state { return true }
        return false
    }

    private func clearFile() {
        selectedFileName = nil
        selectedFileData = nil
        errorMessage = nil
        uploadService.reset()
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
                selectedFileData = try Data(contentsOf: url)
                selectedFileName = url.lastPathComponent
            } catch {
                errorMessage = "Could not read the file: \(error.localizedDescription)"
            }
        }
    }

    private func performUpload() async {
        guard let data = selectedFileData,
              let fileName = selectedFileName,
              let category = selectedCategory,
              let encryptionKey = wallet.encryptionKey else {
            errorMessage = "Fill in all required fields and connect your wallet."
            return
        }

        errorMessage = nil
        do {
            _ = try await uploadService.upload(
                fileData: data,
                fileName: fileName,
                category: category,
                recordDate: recordDate,
                providerName: providerName.isEmpty ? nil : providerName,
                notes: notes.isEmpty ? nil : notes,
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
