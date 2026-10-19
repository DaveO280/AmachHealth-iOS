// LumaInspectorView.swift
// AmachHealth
//
// Profile → Luma Intelligence → What Luma sees. Shows the numbers Luma is
// given next to a fresh HealthKit read, last night's sleep sessions, recent
// workouts with times and sources, and the exact context sent with the last
// message. Everything here stays on the phone.

import SwiftUI
import UIKit

struct LumaInspectorView: View {
    @ObservedObject private var inspector = LumaContextInspector.shared
    @State private var report: LumaReconciliation?
    @State private var isChecking = false
    @State private var preview: LumaContextInspector.Snapshot?
    @State private var copied = false

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()
            List {
                Section {
                    Text(report?.clock ?? HealthContextBuilder.clockLine())
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                        .listRowBackground(Color.amachSurface)
                } header: { header("Right now") }

                Section {
                    if let report {
                        ForEach(report.rows) { row in numberRow(row) }
                    } else {
                        HStack { Spacer(); ProgressView().tint(Color.amachAI); Spacer() }
                            .listRowBackground(Color.amachSurface)
                    }
                    Button(isChecking ? "Checking…" : "Check again") { Task { await check() } }
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachAI)
                        .disabled(isChecking)
                        .listRowBackground(Color.amachSurface)
                } header: { header("Luma vs Apple Health") } footer: {
                    Text("Left: what Luma is given. Right: Apple Health read just now.")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }

                if let sessions = report?.sessions, !sessions.isEmpty {
                    Section {
                        ForEach(sessions) { s in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(time(s.start))–\(time(s.end))")
                                        .font(AmachType.dataMono)
                                        .foregroundStyle(Color.amachTextPrimary)
                                    Text(s.source)
                                        .font(AmachType.tiny)
                                        .foregroundStyle(Color.amachTextSecondary)
                                }
                                Spacer()
                                Text(LumaReconciliation.hoursText(s.asleepMinutes / 60))
                                    .font(AmachType.tiny)
                                    .foregroundStyle(s.counted ? Color.amachTextPrimary : Color.amachTextSecondary)
                                if !s.counted {
                                    Text("not counted")
                                        .font(AmachType.tiny)
                                        .foregroundStyle(Color.amachTextSecondary)
                                }
                            }
                            .listRowBackground(Color.amachSurface)
                        }
                    } header: { header("Last night's sleep") } footer: {
                        Text("When two sources record the same night, one is counted: the one with sleep stages, then the one with more sleep.")
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                }

                if let report {
                    Section {
                        if report.workouts.isEmpty {
                            Text("No workouts in Apple Health in the last 48 hours.")
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.amachTextSecondary)
                                .listRowBackground(Color.amachSurface)
                        }
                        ForEach(Array(report.workouts.enumerated()), id: \.offset) { _, w in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(w.activityType), \(Int(w.durationMinutes.rounded())) min")
                                    .font(AmachType.caption)
                                    .foregroundStyle(Color.amachTextPrimary)
                                Text("\(dayTime(w.date))\(w.endDate.map { "–" + time($0) } ?? "") · \(w.sourceName ?? "unknown source")")
                                    .font(AmachType.tiny)
                                    .foregroundStyle(Color.amachTextSecondary)
                            }
                            .listRowBackground(Color.amachSurface)
                        }
                    } header: { header("Workouts in Apple Health, last 48 h") }
                }

                contextSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("What Luma sees")
        .navigationBarTitleDisplayMode(.inline)
        .task { await check() }
    }

    // MARK: - Context

    private var shown: LumaContextInspector.Snapshot? { preview ?? inspector.lastSent }

    @ViewBuilder
    private var contextSection: some View {
        Section {
            if let snapshot = shown {
                Text("\(preview == nil ? "Sent" : "Preview built") \(dayTime(snapshot.sentAt)) · intent \(snapshot.intent) · \(snapshot.mode)")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
                    .listRowBackground(Color.amachSurface)
                ForEach(Array(snapshot.blocks.enumerated()), id: \.offset) { _, block in
                    DisclosureGroup {
                        Text(block.content)
                            .font(AmachType.dataMono)
                            .foregroundStyle(Color.amachTextPrimary)
                            .textSelection(.enabled)
                    } label: {
                        Text(block.type)
                            .font(AmachType.caption)
                            .foregroundStyle(Color.amachTextPrimary)
                    }
                    .listRowBackground(Color.amachSurface)
                }
                Button(copied ? "Copied" : "Copy full context") {
                    UIPasteboard.general.string = snapshot.json
                    copied = true
                }
                .font(AmachType.caption)
                .foregroundStyle(Color.amachAI)
                .listRowBackground(Color.amachSurface)
            } else {
                Text("Nothing sent yet. Ask Luma something, or build a preview.")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
                    .listRowBackground(Color.amachSurface)
            }
            Button(preview == nil ? "Build preview now" : "Show last sent instead") {
                preview = preview == nil ? inspector.preview() : nil
                copied = false
            }
            .font(AmachType.caption)
            .foregroundStyle(Color.amachAI)
            .listRowBackground(Color.amachSurface)
        } header: { header("What Luma received") }
    }

    // MARK: - Pieces

    private func numberRow(_ row: LumaReconciliation.Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: row.matches == false ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(row.matches == false ? Color.amachWarning : Color.amachSuccess)
                Text(row.label)
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
                Spacer()
                Text(row.lumaValue)
                    .font(AmachType.dataMono)
                    .foregroundStyle(Color.amachAI)
                Text("·").foregroundStyle(Color.amachTextSecondary)
                Text(row.healthKitValue)
                    .font(AmachType.dataMono)
                    .foregroundStyle(Color.amachTextPrimary)
            }
            if let note = row.note {
                Text(note)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .listRowBackground(Color.amachSurface)
    }

    private func header(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AmachType.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(Color.amachTextSecondary)
            .tracking(1)
    }

    private func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func dayTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f.string(from: date)
    }

    private func check() async {
        isChecking = true
        await DashboardService.shared.load(force: false)
        report = await LumaReconciliation.run()
        isChecking = false
    }
}
