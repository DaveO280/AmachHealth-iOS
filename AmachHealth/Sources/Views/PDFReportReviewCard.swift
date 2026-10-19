// PDFReportReviewCard.swift
// AmachHealth
//
// Shows what was read from a PDF before anything is saved: who read it
// (private AI or an offline parser), the values found, and warnings when
// the result looks thin. The user saves or discards.

import SwiftUI

struct PDFReportReviewCard: View {
    let result: PDFReadResult
    let onSave: () -> Void
    let onDiscard: () -> Void
    var onTryAI: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            readerBadge
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachWarning)
            }
            summary
            details
            HStack(spacing: AmachSpacing.sm) {
                Button("Discard", action: onDiscard)
                    .amachSecondaryButtonStyle()
                Button("Save to my vault", action: onSave)
                    .amachPrimaryButtonStyle()
            }
            if let onTryAI, result.reader == .phoneParser {
                Button("Try the private AI again", action: onTryAI)
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachPrimaryBright)
            }
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }

    // MARK: - Reader

    private var readerBadge: some View {
        HStack(spacing: AmachSpacing.sm) {
            Image(systemName: readerIcon)
                .foregroundStyle(result.reader.isAI ? Color.amachAI : Color.amachTextSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(readerTitle)
                    .font(AmachType.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.amachTextPrimary)
                Text(readerDetail)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
    }

    private var readerIcon: String { result.reader.isAI ? "sparkles" : "doc.text.magnifyingglass" }

    private var readerTitle: String {
        switch result.reader {
        case .privateAI: return "Read by private AI"
        case .serverParser: return "Read by Amach's offline parser"
        case .phoneParser: return "Read by this phone's offline reader"
        }
    }

    private var readerDetail: String {
        let time = Self.duration(result.seconds)
        switch result.reader {
        case .privateAI(let model): return [model, time].compactMap { $0 }.joined(separator: " · ")
        case .serverParser(let problem): return "The private AI couldn't map it\(problem.map { " (\($0))" } ?? "") · \(time)"
        case .phoneParser: return "Faster, but can miss values on unusual layouts. Check before saving."
        }
    }

    // MARK: - Contents

    private var warnings: [String] {
        var out: [String] = []
        switch result.report {
        case .bloodwork(let bw):
            if bw.metrics.isEmpty { out.append("No lab values were found.") }
            else if bw.metrics.count < 5 { out.append("Only \(bw.metrics.count) values were found. The report may have more.") }
        case .dexa(let dx):
            if dx.totalBodyFatPercent == nil && dx.totalLeanMassKg == nil && dx.regions.isEmpty {
                out.append("No body-composition values were found.")
            }
        case .medicalRecord(let mr):
            if mr.appearsNonMedical { out.append(MedicalRecordData.noMedicalContentNote) }
            else if (mr.keyFindings ?? []).isEmpty && (mr.summary ?? "").isEmpty {
                out.append("Saved as a general document: no findings were extracted.")
            }
        }
        return out
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)
            Text(subtitle)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
        }
    }

    private var title: String {
        switch result.report {
        case .bloodwork(let bw): return "Bloodwork · \(bw.metrics.count) values"
        case .dexa: return "DEXA scan"
        case .medicalRecord(let mr): return mr.title ?? "Medical document"
        }
    }

    private var subtitle: String {
        switch result.report {
        case .bloodwork(let bw): return [bw.laboratory, bw.reportDate].compactMap { $0 }.joined(separator: " · ")
        case .dexa(let dx): return [dx.source, dx.scanDate].compactMap { $0 }.joined(separator: " · ")
        case .medicalRecord(let mr): return [mr.documentType, mr.reportDate].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private var details: some View {
        switch result.report {
        case .bloodwork(let bw):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bw.metrics.prefix(200).enumerated()), id: \.offset) { _, m in
                    HStack(alignment: .firstTextBaseline) {
                        Text(m.name)
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextPrimary)
                            .lineLimit(2)
                        Spacer()
                        Text(Self.value(m))
                            .font(AmachType.dataMono)
                            .foregroundStyle(Self.flagColor(m.flag))
                    }
                }
            }
        case .dexa(let dx):
            VStack(alignment: .leading, spacing: 6) {
                row("Body fat", dx.totalBodyFatPercent.map { String(format: "%.1f %%", $0) })
                row("Lean mass", dx.totalLeanMassKg.map { String(format: "%.1f kg", $0) })
                row("Visceral fat", dx.visceralFatRating.map { String(format: "%.1f", $0) })
                row("Android/Gynoid", dx.androidGynoidRatio.map { String(format: "%.2f", $0) })
                row("Bone density T-score", dx.boneDensityTotal?.tScore.map { String(format: "%.1f", $0) })
                row("Body regions", dx.regions.isEmpty ? nil : "\(dx.regions.count)")
            }
        case .medicalRecord(let mr):
            VStack(alignment: .leading, spacing: 6) {
                if let s = mr.summary, !mr.appearsNonMedical {
                    Text(s).font(AmachType.tiny).foregroundStyle(Color.amachTextPrimary)
                }
                ForEach(mr.keyFindings ?? [], id: \.self) { f in
                    Text("• \(f)").font(AmachType.tiny).foregroundStyle(Color.amachTextSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            HStack {
                Text(label).font(AmachType.tiny).foregroundStyle(Color.amachTextPrimary)
                Spacer()
                Text(value).font(AmachType.dataMono).foregroundStyle(Color.amachTextPrimary)
            }
        }
    }

    static func value(_ m: BloodworkMetric) -> String {
        let number: String
        if let v = m.value {
            number = v == v.rounded() && abs(v) < 1e6 ? String(Int(v)) : String(format: "%g", v)
        } else {
            number = m.valueText ?? "—"
        }
        return [number, m.unit].compactMap { $0 }.joined(separator: " ")
    }

    static func flagColor(_ flag: BloodworkFlag?) -> Color {
        switch flag {
        case "high", "low": return Color.amachWarning
        case "critical-high", "critical-low": return Color.amachDestructive
        default: return Color.amachTextPrimary
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
    }
}

extension PDFReadResult.Reader {
    var isAI: Bool { if case .privateAI = self { return true } else { return false } }
}
