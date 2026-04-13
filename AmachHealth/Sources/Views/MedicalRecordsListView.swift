// MedicalRecordsListView.swift
// AmachHealth
//
// Displays the user's uploaded medical records.
//
// Default filter: renderingHint == .documentOnly
//   (so bloodwork and DEXA don't double up with their dashboards)
// Toggle: "Show all records including structured"
// Sort:   recordDate desc (default) or uploadedAt desc
// Filter: by category
//
// Tapping a record opens MedicalRecordDetailView showing metadata + source doc info.

import SwiftUI

struct MedicalRecordsListView: View {
    @EnvironmentObject private var wallet: WalletService
    @StateObject private var service = MedicalRecordUploadService.shared

    @State private var records: [MedicalRecordMetadata] = []
    @State private var isLoading = false
    @State private var loadError: String?

    @State private var showAllRecords    = false
    @State private var selectedCategory: MedicalRecordCategory?
    @State private var sortByRecordDate  = true   // false → sort by uploadedAt
    @State private var showingUpload     = false

    private var filteredRecords: [MedicalRecordMetadata] {
        var result = records

        // Default: exclude structured records (bloodwork/DEXA have their own dashboards)
        if !showAllRecords {
            result = result.filter { $0.renderingHint == .documentOnly }
        }

        // Category filter
        if let cat = selectedCategory {
            result = result.filter { $0.category == cat }
        }

        // Sort
        if sortByRecordDate {
            result.sort { $0.recordDate > $1.recordDate }
        } else {
            result.sort { $0.uploadedAt > $1.uploadedAt }
        }

        return result
    }

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .tint(Color.amachPrimaryBright)
            } else if let error = loadError {
                VStack(spacing: AmachSpacing.md) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Color.amachWarning)
                    Text(error)
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") { Task { await loadRecords() } }
                        .amachSecondaryButtonStyle()
                }
                .padding(AmachSpacing.xl)
            } else {
                contentList
            }
        }
        .navigationTitle("Medical Records")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingUpload) {
            UploadMedicalRecordSheet {
                await loadRecords()
            }
            .environmentObject(wallet)
            .presentationBackground(Color.amachSurface)
        }
        .task(id: wallet.isConnected) {
            if wallet.isConnected { await loadRecords() }
        }
    }

    // MARK: - Content list

    private var contentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AmachSpacing.md) {
                // Controls strip
                controlsStrip

                // Category chips
                categoryFilterStrip

                if filteredRecords.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredRecords) { record in
                        NavigationLink {
                            MedicalRecordDetailView(record: record)
                                .environmentObject(wallet)
                        } label: {
                            MedicalRecordCard(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(AmachSpacing.md)
        }
    }

    // MARK: - Controls strip

    private var controlsStrip: some View {
        HStack(spacing: AmachSpacing.sm) {
            // Show all toggle
            Toggle(isOn: $showAllRecords) {
                Text("All records")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.amachPrimaryBright))
            .labelsHidden()

            Text(showAllRecords ? "All records" : "Documents only")
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)

            Spacer()

            // Sort toggle
            Button {
                sortByRecordDate.toggle()
            } label: {
                Label(
                    sortByRecordDate ? "By record date" : "By upload date",
                    systemImage: "arrow.up.arrow.down"
                )
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Category filter chips

    private var categoryFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AmachSpacing.xs) {
                // "All" chip
                filterChip(label: "All", icon: "square.grid.2x2", isSelected: selectedCategory == nil) {
                    selectedCategory = nil
                }

                let categories: [MedicalRecordCategory] = showAllRecords
                    ? MedicalRecordCategory.allCases
                    : MedicalRecordCategory.allCases.filter { !$0.isLaneA }

                ForEach(categories) { cat in
                    filterChip(label: cat.displayName, icon: cat.icon, isSelected: selectedCategory == cat) {
                        selectedCategory = selectedCategory == cat ? nil : cat
                    }
                }
            }
        }
    }

    private func filterChip(
        label: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text(label).font(AmachType.tiny)
            }
            .padding(.horizontal, AmachSpacing.sm)
            .padding(.vertical, 6)
            .background(isSelected ? Color.amachPrimary.opacity(0.15) : Color.amachSurface)
            .foregroundStyle(isSelected ? Color.amachPrimaryBright : Color.amachTextSecondary)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(
                isSelected ? Color.amachPrimaryBright.opacity(0.4) : Color.clear,
                lineWidth: 1
            ))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: AmachSpacing.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.amachTextSecondary.opacity(0.4))
            Text(emptyStateMessage)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
                .multilineTextAlignment(.center)
            Button {
                showingUpload = true
            } label: {
                Label("Upload a Record", systemImage: "plus.circle")
            }
            .amachSecondaryButtonStyle()
        }
        .padding(AmachSpacing.xl)
        .frame(maxWidth: .infinity)
    }

    private var emptyStateMessage: String {
        if selectedCategory != nil {
            return "No records in this category."
        }
        return showAllRecords
            ? "No medical records uploaded yet."
            : "No document records yet. Bloodwork and DEXA are shown on your dashboard."
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingUpload = true
            } label: {
                Image(systemName: "plus")
            }
            .foregroundStyle(Color.amachPrimaryBright)
        }
    }

    // MARK: - Load

    private func loadRecords() async {
        guard let encryptionKey = wallet.encryptionKey else { return }
        isLoading = true
        loadError = nil
        do {
            records = try await AmachAPIClient.shared.listMedicalRecords(
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey
            )
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Record Card

struct MedicalRecordCard: View {
    let record: MedicalRecordMetadata

    var body: some View {
        HStack(spacing: AmachSpacing.md) {
            // Category icon
            ZStack {
                RoundedRectangle(cornerRadius: AmachRadius.sm)
                    .fill(Color.amachPrimary.opacity(0.10))
                    .frame(width: 40, height: 40)
                Image(systemName: record.category.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.amachPrimaryBright)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(record.fileName)
                    .font(AmachType.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.amachTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(record.category.displayName)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                    Text("·")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                    Text(formattedRecordDate)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }

                if let provider = record.providerName {
                    Text(provider)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
                }
            }

            Spacer()

            parserBadge
        }
        .padding(AmachSpacing.md)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AmachRadius.card)
                .stroke(Color.amachPrimary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var parserBadge: some View {
        switch record.parserStatus {
        case .succeeded:
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(Color.amachSuccess)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Color.amachWarning)
        case .pending:
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(Color.amachTextSecondary)
        default:
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(Color.amachTextSecondary.opacity(0.4))
        }
    }

    private var formattedRecordDate: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        guard let date = f.date(from: record.recordDate) else { return record.recordDate }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: date)
    }
}

// MARK: - Record Detail View

struct MedicalRecordDetailView: View {
    let record: MedicalRecordMetadata
    @EnvironmentObject private var wallet: WalletService

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                    headerCard
                    metadataCard
                    storageCard
                    if record.category.isLaneA { parserCard }
                }
                .padding(AmachSpacing.md)
            }
        }
        .navigationTitle(record.category.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerCard: some View {
        HStack(spacing: AmachSpacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: AmachRadius.md)
                    .fill(Color.amachPrimary.opacity(0.12))
                    .frame(width: 56, height: 56)
                Image(systemName: record.category.icon)
                    .font(.title2)
                    .foregroundStyle(Color.amachPrimaryBright)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.fileName)
                    .font(AmachType.h3)
                    .foregroundStyle(Color.amachTextPrimary)
                    .lineLimit(2)
                Text(record.category.displayName)
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Details")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            detailRow(label: "Record Date",  value: formattedDate(record.recordDate))
            detailRow(label: "Uploaded",     value: formattedDate(record.uploadedAt))
            detailRow(label: "Size",         value: formattedSize(record.sizeBytes))
            detailRow(label: "Type",         value: record.mimeType)
            if let provider = record.providerName {
                detailRow(label: "Provider", value: provider)
            }
            if let notes = record.notes {
                detailRow(label: "Notes", value: notes)
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Storage")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            detailRow(label: "Record ID",    value: String(record.id.prefix(16)) + "…")
            detailRow(label: "Rendering",    value: record.renderingHint.rawValue)

            Text(record.storjKey)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.amachTextSecondary.opacity(0.6))
                .lineLimit(2)
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    @ViewBuilder
    private var parserCard: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Data Extraction")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)

            HStack(spacing: AmachSpacing.sm) {
                Image(systemName: parserStatusIcon)
                    .foregroundStyle(parserStatusColor)
                Text(parserStatusLabel)
                    .font(AmachType.caption)
                    .foregroundStyle(parserStatusColor)
            }

            if let ref = record.parsedDataRef {
                Text(ref)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.amachTextSecondary.opacity(0.6))
                    .lineLimit(2)
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    // MARK: - Helpers

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextPrimary)
                .multilineTextAlignment(.leading)
        }
    }

    private func formattedDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        if let d = f.date(from: iso) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df.string(from: d)
        }
        // Try full ISO8601
        let f2 = ISO8601DateFormatter()
        if let d = f2.date(from: iso) {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df.string(from: d)
        }
        return iso
    }

    private func formattedSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1024)
    }

    private var parserStatusIcon: String {
        switch record.parserStatus {
        case .succeeded:     return "checkmark.seal.fill"
        case .failed:        return "exclamationmark.triangle.fill"
        case .pending:       return "hourglass"
        case .skipped:       return "slash.circle"
        case .notApplicable: return "minus.circle"
        }
    }

    private var parserStatusColor: Color {
        switch record.parserStatus {
        case .succeeded:     return Color.amachSuccess
        case .failed:        return Color.amachWarning
        case .pending:       return Color.amachTextSecondary
        default:             return Color.amachTextSecondary
        }
    }

    private var parserStatusLabel: String {
        switch record.parserStatus {
        case .succeeded:     return "Data extracted and linked to your dashboard"
        case .failed:        return "Extraction failed — stored as document only"
        case .pending:       return "Extraction pending"
        case .skipped:       return "Extraction skipped (non-PDF)"
        case .notApplicable: return "Not applicable"
        }
    }
}
