// UploadLabDataSheet.swift
// AmachHealth

import SwiftUI

struct UploadLabDataSheet: View {
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var wallet: WalletService

    @State private var mode: LabRecordMode = .bloodwork
    @State private var sampleDate = Date()
    @State private var values: [String: String] = [:]
    @State private var notes = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                        Picker("Record type", selection: $mode) {
                            ForEach(LabRecordMode.allCases, id: \.self) { candidate in
                                Text(candidate.title).tag(candidate)
                            }
                        }
                        .pickerStyle(.segmented)

                        dateField
                        fieldList
                        notesField

                        if let error {
                            Text(error)
                                .font(AmachType.caption)
                                .foregroundStyle(Color.amachDestructive)
                        }

                        Button {
                            Task { await save() }
                        } label: {
                            Text("Save to Storj")
                        }
                        .amachPrimaryButtonStyle(isLoading: isSaving)
                        .disabled(!canSave || isSaving)
                    }
                    .padding(AmachSpacing.md)
                }
            }
            .navigationTitle("Add Lab Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.amachPrimaryBright)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var dateField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Date")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)

            DatePicker(
                "Date",
                selection: $sampleDate,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .padding(.horizontal, AmachSpacing.md)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.amachSurface)
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AmachRadius.sm)
                    .stroke(Color.amachPrimary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private var fieldList: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            ForEach(mode.fields, id: \.key) { field in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(field.label) (\(field.unit))")
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)

                    TextField(field.placeholder, text: binding(for: field.key))
                        .keyboardType(.decimalPad)
                        .padding(.horizontal, AmachSpacing.md)
                        .padding(.vertical, 14)
                        .background(Color.amachSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AmachRadius.sm)
                                .stroke(Color.amachPrimary.opacity(0.12), lineWidth: 1)
                        )
                }
            }
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes (optional)")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)

            TextField("Quest panel, fasting 12h", text: $notes, axis: .vertical)
                .lineLimit(3...5)
                .padding(.horizontal, AmachSpacing.md)
                .padding(.vertical, 14)
                .background(Color.amachSurface)
                .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: AmachRadius.sm)
                        .stroke(Color.amachPrimary.opacity(0.12), lineWidth: 1)
                )
        }
    }

    private var canSave: Bool {
        mode.fields.contains { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func save() async {
        guard let encryptionKey = wallet.encryptionKey else {
            error = "Connect your wallet before uploading lab data."
            return
        }

        let parsedValues = mode.fields.reduce(into: [String: Double]()) { partial, field in
            let raw = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let numeric = Double(raw) {
                partial[field.key] = numeric
            }
        }

        guard !parsedValues.isEmpty else {
            error = "Enter at least one lab value before saving."
            return
        }

        isSaving = true
        error = nil
        defer { isSaving = false }

        let record = LabRecord(
            id: UUID().uuidString.lowercased(),
            date: sampleDate,
            type: mode.dataType,
            values: parsedValues,
            units: Dictionary(uniqueKeysWithValues: mode.fields.map { ($0.key, $0.unit) }),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
            attestationTxHash: nil
        )

        do {
            _ = try await AmachAPIClient.shared.storeLabRecord(
                data: record,
                dataType: mode.dataType,
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey
            )
            await onSaved()
            AmachHaptics.success()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LabRecordDetailView: View {
    let item: StorjListItem

    @EnvironmentObject private var wallet: WalletService

    @State private var record: LabRecord?
    @State private var bloodworkReport: RemoteBloodworkReport?
    @State private var dexaReport: RemoteDexaReport?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            Group {
                if isLoading {
                    ProgressView()
                        .tint(Color.amachPrimaryBright)
                } else if let error {
                    Text(error)
                        .font(AmachType.body)
                        .foregroundStyle(Color.amachDestructive)
                        .padding()
                } else if let record {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                            VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                                HStack {
                                    Text(record.title)
                                        .font(AmachType.h2)
                                        .foregroundStyle(Color.amachTextPrimary)
                                    Spacer()
                                    Text(record.date, style: .date)
                                        .font(AmachType.caption)
                                        .foregroundStyle(Color.amachTextSecondary)
                                }

                                if let txHash = item.attestationTxHash ?? record.attestationTxHash {
                                    Label("Verified on ZKsync", systemImage: "checkmark.seal.fill")
                                        .font(AmachType.tiny)
                                        .foregroundStyle(Color.amachSuccess)
                                    Text(shortHash(txHash))
                                        .font(AmachType.dataMono)
                                        .foregroundStyle(Color.amachTextSecondary)
                                }
                            }
                            .padding(AmachSpacing.lg)
                            .amachCard()

                            VStack(alignment: .leading, spacing: AmachSpacing.md) {
                                Text("Values")
                                    .font(AmachType.h3)
                                    .foregroundStyle(Color.amachTextPrimary)

                                ForEach(record.values.keys.sorted(), id: \.self) { key in
                                    HStack {
                                        Text(displayName(for: key))
                                            .font(AmachType.caption)
                                            .foregroundStyle(Color.amachTextSecondary)
                                        Spacer()
                                        let value = record.values[key] ?? 0
                                        let unit = record.units[key] ?? ""
                                        Text("\(formatted(value)) \(unit)".trimmingCharacters(in: .whitespaces))
                                            .font(AmachType.dataMono)
                                            .foregroundStyle(Color.amachTextPrimary)
                                    }
                                }
                            }
                            .padding(AmachSpacing.lg)
                            .amachCard()

                            if let notes = record.notes, !notes.isEmpty {
                                VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                                    Text("Notes")
                                        .font(AmachType.h3)
                                        .foregroundStyle(Color.amachTextPrimary)
                                    Text(notes)
                                        .font(AmachType.body)
                                        .foregroundStyle(Color.amachTextSecondary)
                                }
                                .padding(AmachSpacing.lg)
                                .amachCard()
                            }
                        }
                        .padding(AmachSpacing.md)
                    }
                } else if let bloodworkReport {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                            reportHeaderCard(
                                title: "Bloodwork",
                                dateText: bloodworkReport.reportDate,
                                txHash: item.attestationTxHash
                            )

                            VStack(alignment: .leading, spacing: AmachSpacing.md) {
                                Text("Metrics")
                                    .font(AmachType.h3)
                                    .foregroundStyle(Color.amachTextPrimary)

                                ForEach(bloodworkDisplayMetrics(bloodworkReport)) { metric in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(metric.name)
                                                .font(AmachType.caption)
                                                .foregroundStyle(Color.amachTextSecondary)
                                            if let referenceRange = metric.referenceRange, !referenceRange.isEmpty {
                                                Text(referenceRange)
                                                    .font(AmachType.tiny)
                                                    .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
                                            }
                                        }

                                        Spacer()

                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(renderedBloodworkMetric(metric))
                                                .font(AmachType.dataMono)
                                                .foregroundStyle(Color.amachTextPrimary)
                                            if let flag = metric.flag, !flag.isEmpty {
                                                Text(flag.replacingOccurrences(of: "-", with: " ").capitalized)
                                                    .font(AmachType.tiny)
                                                    .foregroundStyle(Color.amachWarning)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(AmachSpacing.lg)
                            .amachCard()

                            if let notes = bloodworkReport.notes, !notes.isEmpty {
                                notesCard(notes.joined(separator: "\n"))
                            }
                        }
                        .padding(AmachSpacing.md)
                    }
                } else if let dexaReport {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                            reportHeaderCard(
                                title: "DEXA Scan",
                                dateText: dexaReport.scanDate,
                                txHash: item.attestationTxHash
                            )

                            VStack(alignment: .leading, spacing: AmachSpacing.md) {
                                Text("Summary")
                                    .font(AmachType.h3)
                                    .foregroundStyle(Color.amachTextPrimary)

                                ForEach(Array(dexaSummaryRows(dexaReport).enumerated()), id: \.offset) { _, row in
                                    HStack {
                                        Text(row.label)
                                            .font(AmachType.caption)
                                            .foregroundStyle(Color.amachTextSecondary)
                                        Spacer()
                                        Text(row.value)
                                            .font(AmachType.dataMono)
                                            .foregroundStyle(Color.amachTextPrimary)
                                    }
                                }
                            }
                            .padding(AmachSpacing.lg)
                            .amachCard()

                            if let notes = dexaReport.notes, !notes.isEmpty {
                                notesCard(notes.joined(separator: "\n"))
                            }
                        }
                        .padding(AmachSpacing.md)
                    }
                }
            }
        }
        .navigationTitle("Lab Record")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadRecord() }
    }

    private func loadRecord() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let encryptionKey = try await wallet.ensureEncryptionKey()
            record = nil
            bloodworkReport = nil
            dexaReport = nil

            switch item.dataType {
            case "bloodwork-report-fhir":
                bloodworkReport = try await AmachAPIClient.shared.retrieveBloodworkReport(
                    storjUri: item.uri,
                    walletAddress: encryptionKey.walletAddress,
                    encryptionKey: encryptionKey
                )
            case "dexa-report-fhir":
                dexaReport = try await AmachAPIClient.shared.retrieveDexaReport(
                    storjUri: item.uri,
                    walletAddress: encryptionKey.walletAddress,
                    encryptionKey: encryptionKey
                )
            default:
                record = try await AmachAPIClient.shared.retrieveStoredData(
                    storjUri: item.uri,
                    walletAddress: encryptionKey.walletAddress,
                    encryptionKey: encryptionKey,
                    as: LabRecord.self
                )
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func formatted(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func displayName(for key: String) -> String {
        key
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .capitalized
    }

    private func bloodworkDisplayMetrics(_ report: RemoteBloodworkReport) -> [RemoteBloodworkMetric] {
        report.metrics.filter {
            $0.value != nil || (($0.valueText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) == false)
        }
    }

    private func renderedBloodworkMetric(_ metric: RemoteBloodworkMetric) -> String {
        if let valueText = metric.valueText, !valueText.isEmpty {
            let unit = metric.unit.map { " \($0)" } ?? ""
            return "\(valueText)\(unit)"
        }

        if let value = metric.value {
            let unit = metric.unit.map { " \($0)" } ?? ""
            return "\(formatted(value))\(unit)"
        }

        return "Not available"
    }

    private func dexaSummaryRows(_ report: RemoteDexaReport) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []

        func append(_ label: String, _ value: Double?, suffix: String = "") {
            guard let value else { return }
            let rendered = formatted(value)
            rows.append((label, "\(rendered)\(suffix)"))
        }

        append("Body Fat", report.totalBodyFatPercent, suffix: "%")
        append("Lean Mass", report.totalLeanMassKg, suffix: " kg")
        append("Visceral Fat Rating", report.visceralFatRating)
        append("Visceral Fat Area", report.visceralFatAreaCm2, suffix: " cm2")
        append("Visceral Fat Volume", report.visceralFatVolumeCm3, suffix: " cm3")
        append("Android/Gynoid Ratio", report.androidGynoidRatio)
        append("Bone Density BMD", report.boneDensityTotal?.bmd)
        append("Bone Density T-Score", report.boneDensityTotal?.tScore)
        append("Bone Density Z-Score", report.boneDensityTotal?.zScore)

        return rows
    }

    private func reportHeaderCard(title: String, dateText: String?, txHash: String?) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack {
                Text(title)
                    .font(AmachType.h2)
                    .foregroundStyle(Color.amachTextPrimary)
                Spacer()
                if let dateText, !dateText.isEmpty {
                    Text(dateText)
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }

            if let txHash {
                Label("Verified on ZKsync", systemImage: "checkmark.seal.fill")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachSuccess)
                Text(shortHash(txHash))
                    .font(AmachType.dataMono)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func notesCard(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text("Notes")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)
            Text(notes)
                .font(AmachType.body)
                .foregroundStyle(Color.amachTextSecondary)
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 16 else { return hash }
        return "\(hash.prefix(10))…\(hash.suffix(6))"
    }
}

private extension UploadLabDataSheet {
    struct LabField {
        let key: String
        let label: String
        let unit: String
        let placeholder: String
    }

    enum LabRecordMode: CaseIterable {
        case bloodwork
        case dexa

        var title: String {
            switch self {
            case .bloodwork: return "Bloodwork"
            case .dexa: return "DEXA"
            }
        }

        var dataType: String {
            switch self {
            case .bloodwork: return "bloodwork"
            case .dexa: return "dexa"
            }
        }

        var fields: [LabField] {
            switch self {
            case .bloodwork:
                return [
                    .init(key: "glucose", label: "Glucose", unit: "mg/dL", placeholder: "94"),
                    .init(key: "hba1c", label: "HbA1c", unit: "%", placeholder: "5.2"),
                    .init(key: "totalCholesterol", label: "Total Chol", unit: "mg/dL", placeholder: "182"),
                    .init(key: "ldl", label: "LDL", unit: "mg/dL", placeholder: "98"),
                    .init(key: "hdl", label: "HDL", unit: "mg/dL", placeholder: "62"),
                    .init(key: "triglycerides", label: "Triglycerides", unit: "mg/dL", placeholder: "88"),
                    .init(key: "tsh", label: "TSH", unit: "mIU/L", placeholder: "1.8"),
                    .init(key: "vitaminD", label: "Vitamin D", unit: "ng/mL", placeholder: "42"),
                    .init(key: "ferritin", label: "Ferritin", unit: "ng/mL", placeholder: "85")
                ]
            case .dexa:
                return [
                    .init(key: "bodyFatPct", label: "Body Fat", unit: "%", placeholder: "22.4"),
                    .init(key: "leanMassKg", label: "Lean Mass", unit: "kg", placeholder: "43.2"),
                    .init(key: "boneDensityTScore", label: "Bone Density", unit: "T-score", placeholder: "0.8"),
                    .init(key: "visceralFatLbs", label: "Visceral Fat", unit: "lbs", placeholder: "1.8"),
                    .init(key: "androidGynoidRatio", label: "Android/Gynoid Ratio", unit: "ratio", placeholder: "0.84")
                ]
            }
        }
    }
}
