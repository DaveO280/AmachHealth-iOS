// TimelineView.swift
// AmachHealth

import SwiftUI

struct TimelineView: View {
    @EnvironmentObject private var wallet: WalletService
    @EnvironmentObject private var timeline: TimelineService

    @State private var showingAddEvent = false
    @State private var editingEvent: TimelineEvent? = nil
    @State private var deletingEvent: TimelineEvent? = nil
    @State private var filter: TimelineFilter = .all

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                if !wallet.isConnected {
                    walletGate
                        .padding(AmachSpacing.md)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                            filterChips

                            if timeline.isLoading && timeline.events.isEmpty {
                                ProgressView()
                                    .tint(Color.amachPrimaryBright)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, AmachSpacing.xl)
                            } else if let error = timeline.error, filteredEvents.isEmpty {
                                errorState(error)
                            } else if filteredEvents.isEmpty {
                                emptyState
                            } else {
                                ForEach(groupedDays, id: \.self) { day in
                                    VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                                        Text(daySectionTitle(day))
                                            .font(AmachType.tiny)
                                            .foregroundStyle(Color.amachTextSecondary)
                                            .textCase(.uppercase)

                                        ForEach(groupedEvents[day] ?? []) { event in
                                            TimelineEventCard(
                                                event: event,
                                                onEdit: { editingEvent = event },
                                                onDelete: event.isAnomaly ? nil : { deletingEvent = event }
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .padding(AmachSpacing.md)
                    }
                    .refreshable { await loadEventsIfPossible() }
                }
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if wallet.isConnected {
                        Button {
                            showingAddEvent = true
                        } label: {
                            Label("Add", systemImage: "plus")
                                .foregroundStyle(Color.amachPrimaryBright)
                        }
                    }
                }
            }
            .task { await loadEventsIfPossible() }
            .onChange(of: wallet.isConnected) { _, _ in
                Task { await loadEventsIfPossible() }
            }
            .sheet(isPresented: $showingAddEvent) {
                AddTimelineEventSheet()
                    .environmentObject(wallet)
                    .environmentObject(timeline)
                    .presentationBackground(Color.amachSurface)
            }
            .sheet(item: $editingEvent) { event in
                AddTimelineEventSheet(existingEvent: event)
                    .environmentObject(wallet)
                    .environmentObject(timeline)
                    .presentationBackground(Color.amachSurface)
            }
            .confirmationDialog(
                "Delete Event",
                isPresented: .init(
                    get: { deletingEvent != nil },
                    set: { if !$0 { deletingEvent = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let event = deletingEvent {
                        deletingEvent = nil
                        Task { await performDelete(event: event) }
                    }
                }
                Button("Cancel", role: .cancel) { deletingEvent = nil }
            } message: {
                if let event = deletingEvent {
                    Text("\"\(event.titleText)\" will be removed from your timeline and Storj.")
                }
            }
        }
    }

    private func performDelete(event: TimelineEvent) async {
        guard wallet.isConnected else { return }
        do {
            let encryptionKey = try await wallet.ensureEncryptionKey()
            try await timeline.deleteEvent(
                id: event.id,
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey
            )
            AmachHaptics.success()
        } catch {
            timeline.error = error.localizedDescription
            AmachHaptics.error()
        }
    }

    private var walletGate: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.lg) {
            HStack(spacing: AmachSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: AmachRadius.sm)
                        .fill(Color.amachPrimary.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "lock.fill")
                        .foregroundStyle(Color.amachPrimaryBright)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock Timeline")
                        .font(AmachType.h3)
                        .foregroundStyle(Color.amachTextPrimary)
                    Text("Connect your wallet to view synced events and anomalies across devices.")
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }

            VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                gateFeature("User-entered life events")
                gateFeature("Auto-detected anomaly history")
                gateFeature("Cross-platform Storj sync")
            }
        }
        .padding(AmachSpacing.lg)
        .amachCard()
    }

    private func gateFeature(_ text: String) -> some View {
        HStack(spacing: AmachSpacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.amachPrimaryBright)
            Text(text)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
        }
    }

    private var filterChips: some View {
        HStack(spacing: AmachSpacing.sm) {
            ForEach(TimelineFilter.allCases, id: \.self) { candidate in
                Button {
                    filter = candidate
                    AmachHaptics.toggle()
                } label: {
                    Text(candidate.title)
                        .font(AmachType.caption)
                        .foregroundStyle(filter == candidate ? Color.amachTextPrimary : Color.amachTextSecondary)
                        .padding(.horizontal, AmachSpacing.md)
                        .padding(.vertical, 10)
                        .background(filter == candidate ? Color.amachPrimary.opacity(0.16) : Color.amachSurface)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(
                                    filter == candidate ? Color.amachPrimary.opacity(0.28) : Color.amachPrimary.opacity(0.08),
                                    lineWidth: 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: AmachSpacing.md) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(Color.amachTextSecondary)
            Text("No timeline events yet")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)
            Text("Add a medication, lifestyle change, or note to start building your timeline.")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AmachSpacing.xxl)
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: AmachSpacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.amachWarning)
            Text("Couldn't load timeline")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextPrimary)
            Text(error)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await loadEventsIfPossible() }
            }
            .amachSecondaryButtonStyle()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AmachSpacing.xxl)
    }

    private var filteredEvents: [TimelineEvent] {
        switch filter {
        case .all:
            return timeline.events
        case .events:
            return timeline.events.filter { !$0.isAnomaly }
        case .anomalies:
            return timeline.events.filter(\.isAnomaly)
        }
    }

    private var groupedEvents: [Date: [TimelineEvent]] {
        Dictionary(grouping: filteredEvents) { Calendar.current.startOfDay(for: $0.timestamp) }
    }

    private var groupedDays: [Date] {
        groupedEvents.keys.sorted(by: >)
    }

    private func daySectionTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: day)
    }

    private func loadEventsIfPossible() async {
        guard wallet.isConnected else { return }

        do {
            timelineDebug("Starting Timeline load from view")
            let encryptionKey = try await wallet.ensureEncryptionKey()
            timelineDebug("Using encryption key for \(encryptionKey.walletAddress)")
            await timeline.loadEvents(
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey
            )
            timelineDebug("Timeline load returned \(timeline.events.count) merged events")
        } catch {
            timelineDebug("Timeline load failed before service call: \(error.localizedDescription)")
            timeline.error = error.localizedDescription
        }
    }

    private func timelineDebug(_ message: String) {
        #if DEBUG
        print("🕒 [TimelineView] \(message)")
        #endif
    }
}

private extension TimelineView {
    enum TimelineFilter: CaseIterable {
        case all
        case events
        case anomalies

        var title: String {
            switch self {
            case .all: return "All"
            case .events: return "Events"
            case .anomalies: return "Anomalies"
            }
        }
    }
}

private struct TimelineEventCard: View {
    let event: TimelineEvent
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?

    init(event: TimelineEvent, onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.event = event
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack(alignment: .top, spacing: AmachSpacing.sm) {
                Image(systemName: event.isAnomaly ? "exclamationmark.triangle.fill" : event.eventType.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(event.isAnomaly ? Color.amachWarning : Color.amachPrimaryBright)
                    .frame(width: 32, height: 32)
                    .background(iconBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.isAnomaly ? "Auto-detected" : event.titleText)
                            .font(AmachType.h3)
                            .foregroundStyle(Color.amachTextPrimary)

                        if event.isAnomaly {
                            Text("AUTO")
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.Amach.Semantic.warningTextD)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.Amach.Semantic.warningBgD)
                                .clipShape(Capsule())
                        }
                    }

                    if let subtitle = event.subtitleText {
                        Text(subtitle)
                            .font(AmachType.caption)
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                }

                Spacer()

                HStack(spacing: AmachSpacing.sm) {
                    Text(event.timestamp, style: .time)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)

                    if !event.isAnomaly {
                        if let onEdit {
                            Button {
                                AmachHaptics.cardTap()
                                onEdit()
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.amachTextSecondary)
                                    .frame(width: 28, height: 28)
                                    .background(Color.amachPrimary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: AmachRadius.xs))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit event")
                        }

                        if let onDelete {
                            Button {
                                AmachHaptics.buttonPress()
                                onDelete()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.amachDestructive.opacity(0.7))
                                    .frame(width: 28, height: 28)
                                    .background(Color.amachDestructive.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: AmachRadius.xs))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete event")
                        }
                    }
                }
            }

            if event.isAnomaly {
                anomalyMeta
            } else {
                eventFields
            }

            if let txHash = event.attestationTxHash {
                Label("Verified on ZKsync", systemImage: "checkmark.seal.fill")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachSuccess)

                Text(shortHash(txHash))
                    .font(AmachType.dataMono)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .padding(AmachSpacing.md)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(event.isAnomaly ? Color.amachWarning : Color.amachPrimaryBright)
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
        }
        .overlay(
            RoundedRectangle(cornerRadius: AmachRadius.card)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    private var eventFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(event.data.keys.sorted(), id: \.self) { key in
                if let value = event.data[key], !value.isEmpty {
                    HStack(alignment: .top) {
                        Text(key
                            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                            .capitalized + ":")
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextSecondary)
                        Text(value)
                            .font(AmachType.caption)
                            .foregroundStyle(Color.amachTextPrimary)
                    }
                }
            }
        }
    }

    private var anomalyMeta: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let metricType = event.metricType {
                Text(metricType
                    .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                    .capitalized)
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
            }

            if let deviationPct = event.deviationPct {
                let sign = deviationPct > 0 ? "+" : ""
                Text("\(sign)\(Int(deviationPct.rounded()))% over baseline")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            if let resolvedAt = event.resolvedAt {
                Text("Resolved \(resolvedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachSuccess)
            }
        }
    }

    private var cardBackground: Color {
        event.isAnomaly ? Color.amachWarning.opacity(0.10) : Color.amachSurface
    }

    private var cardBorder: Color {
        event.isAnomaly ? Color.amachWarning.opacity(0.22) : Color.amachPrimary.opacity(0.10)
    }

    private var iconBackground: Color {
        event.isAnomaly ? Color.amachWarning.opacity(0.16) : Color.amachPrimary.opacity(0.12)
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 16 else { return hash }
        return "\(hash.prefix(10))…\(hash.suffix(6))"
    }
}
