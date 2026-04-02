// AddTimelineEventSheet.swift
// AmachHealth

import SwiftUI

struct AddTimelineEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var wallet: WalletService
    @EnvironmentObject private var timeline: TimelineService

    let existingEvent: TimelineEvent?

    init(existingEvent: TimelineEvent? = nil) {
        self.existingEvent = existingEvent
        if let event = existingEvent {
            _step = State(initialValue: .details)
            _selectedType = State(initialValue: event.eventType)
            _fieldValues = State(initialValue: event.data)
            _eventDate = State(initialValue: event.timestamp)
        }
    }

    @State private var step: AddStep = .type
    @State private var selectedType: TimelineEventType?
    @State private var fieldValues: [String: String] = [:]
    @State private var eventDate = Date()
    @State private var isSaving = false
    @State private var error: String?

    private var isEditMode: Bool { existingEvent != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: AmachSpacing.lg) {
                        header

                        if step == .type {
                            typePicker
                        } else {
                            detailsForm
                        }
                    }
                    .padding(AmachSpacing.md)
                }
            }
            .navigationTitle(isEditMode ? "Edit Health Event" : "Add Health Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(step == .details ? "Back" : "Cancel") {
                        if step == .details {
                            step = .type
                        } else {
                            dismiss()
                        }
                    }
                    .foregroundStyle(Color.amachPrimaryBright)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            Text(step == .type ? "Choose an event type" : (selectedType?.displayName ?? "Event Details"))
                .font(AmachType.h2)
                .foregroundStyle(Color.amachTextPrimary)

            Text(step == .type
                 ? "Timeline events sync to Storj so they can appear across iOS and web."
                 : (isEditMode ? "Update the details below and save to sync changes." : "Add the key details below. Required fields must be filled before saving."))
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
        }
    }

    private var typePicker: some View {
        VStack(spacing: AmachSpacing.sm) {
            ForEach(TimelineEventType.allCases) { type in
                Button {
                    selectedType = type
                    fieldValues = [:]
                    step = .details
                    AmachHaptics.cardTap()
                } label: {
                    HStack(spacing: AmachSpacing.md) {
                        Image(systemName: type.icon)
                            .font(.system(size: 16))
                            .foregroundStyle(Color.amachPrimaryBright)
                            .frame(width: 36, height: 36)
                            .background(Color.amachPrimary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))

                        Text(type.displayName)
                            .font(AmachType.body)
                            .foregroundStyle(Color.amachTextPrimary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                    .padding(AmachSpacing.md)
                    .amachCard()
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var detailsForm: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            if let selectedType {
                ForEach(selectedType.fields, id: \.key) { field in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(field.required ? "\(field.label) *" : field.label)
                            .font(AmachType.caption)
                            .foregroundStyle(Color.amachTextSecondary)

                        TextField(field.placeholder, text: binding(for: field.key))
                            .textInputAutocapitalization(.sentences)
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("Date")
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)

                    DatePicker(
                        "Event date",
                        selection: $eventDate,
                        displayedComponents: [.date, .hourAndMinute]
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

                if let error {
                    Text(error)
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachDestructive)
                }

                Button {
                    Task { await saveEvent() }
                } label: {
                    HStack {
                        if isSaving {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.85)
                        }
                        Text(isEditMode ? "Update Event" : "Save Event")
                    }
                }
                .amachPrimaryButtonStyle(isLoading: isSaving)
                .disabled(!canSave || isSaving)
            }
        }
    }

    private var canSave: Bool {
        guard let selectedType else { return false }
        return selectedType.fields
            .filter(\.required)
            .allSatisfy { !(fieldValues[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { fieldValues[key] ?? "" },
            set: { fieldValues[key] = $0 }
        )
    }

    private func saveEvent() async {
        guard let selectedType else { return }
        guard let encryptionKey = wallet.encryptionKey else {
            error = "Connect your wallet before saving timeline events."
            return
        }

        isSaving = true
        error = nil
        defer { isSaving = false }

        let cleanedValues = fieldValues.reduce(into: [String: String]()) { partial, pair in
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                partial[pair.key] = value
            }
        }

        if let existing = existingEvent {
            let updatedEvent = TimelineEvent(
                id: existing.id,
                eventType: selectedType,
                timestamp: eventDate,
                data: cleanedValues,
                metadata: existing.metadata,
                anomalyType: existing.anomalyType,
                metricType: existing.metricType,
                direction: existing.direction,
                deviationPct: existing.deviationPct,
                resolvedAt: existing.resolvedAt,
                attestationTxHash: existing.attestationTxHash
            )
            do {
                try await timeline.updateEvent(
                    updatedEvent,
                    walletAddress: encryptionKey.walletAddress,
                    encryptionKey: encryptionKey
                )
                AmachHaptics.success()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        } else {
            let event = TimelineEvent(
                id: UUID().uuidString.lowercased(),
                eventType: selectedType,
                timestamp: eventDate,
                data: cleanedValues,
                metadata: TimelineEventMetadata(
                    platform: "ios",
                    version: "1",
                    source: .userEntered
                )
            )
            do {
                try await timeline.addEvent(
                    event,
                    walletAddress: encryptionKey.walletAddress,
                    encryptionKey: encryptionKey
                )
                AmachHaptics.success()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private extension AddTimelineEventSheet {
    enum AddStep {
        case type
        case details
    }
}
