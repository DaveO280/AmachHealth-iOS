// EncryptedBackupSection.swift
// AmachHealth
//
// Settings → Encrypted backup: the opt-in toggle, what Storj can see,
// when the vault was last backed up, restore, and the one-time cleanup of
// old objects in the shared Storj account.

import SwiftUI

struct EncryptedBackupSection: View {
    @ObservedObject private var backup = BackupService.shared
    @ObservedObject private var vault = LocalVault.shared
    @State private var confirmCleanup: BackupService.LegacyCleanupPlan?
    @State private var confirmRestore = false

    var body: some View {
        Section {
            HStack(spacing: AmachSpacing.md) {
                Image(systemName: "lock.icloud.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.amachPrimaryBright)
                    .frame(width: 28)
                Text("Encrypted backup")
                    .font(AmachType.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.amachTextPrimary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { backup.isEnabled },
                    set: { backup.setEnabled($0) }
                ))
                .labelsHidden()
                .tint(Color.amachPrimary)
                .disabled(!vault.isOpen)
            }
            .listRowBackground(Color.amachSurface)

            Text(Self.explanation)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
                .lineSpacing(2)
                .listRowBackground(Color.amachSurface)

            if backup.isEnabled || backup.lastBackedUpAt != nil {
                statusRow
                if backup.isEnabled {
                    actionRow("Back up now", icon: "arrow.up.circle", disabled: backup.isBusy) {
                        backup.backUpNow()
                    }
                }
            }
            actionRow("Restore from backup", icon: "arrow.down.circle", disabled: backup.isBusy || !vault.isOpen) {
                confirmRestore = true
            }

            legacyCleanupRows
        } header: {
            Text("ENCRYPTED BACKUP")
                .font(AmachType.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(Color.amachTextSecondary)
                .tracking(1)
        }
        .confirmationDialog(
            "Restore from your encrypted backup?",
            isPresented: $confirmRestore, titleVisibility: .visible
        ) {
            Button("Restore") { backup.restoreNow() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything in the backup that isn't on this phone is added back. Nothing on this phone is overwritten.")
        }
        .confirmationDialog(
            "Delete old copies from Storj?",
            isPresented: Binding(get: { confirmCleanup != nil }, set: { if !$0 { confirmCleanup = nil } }),
            titleVisibility: .visible,
            presenting: confirmCleanup
        ) { plan in
            Button("Delete \(plan.deletable.count) old objects", role: .destructive) {
                backup.performLegacyCleanup(plan)
            }
            Button("Keep them", role: .cancel) {}
        } message: { plan in
            Text(Self.cleanupMessage(plan))
        }
    }

    static let explanation = """
    When this is on, your health data is encrypted on this phone before it leaves, with a key only \
    your wallet can recreate. Storj stores scrambled data it can't read, and so does Amach. \
    When it's off, your data lives only on this phone: lose the phone and the data goes with it.
    """

    static func cleanupMessage(_ plan: BackupService.LegacyCleanupPlan) -> String {
        var text = "Your encrypted backup was checked end to end. These \(plan.deletable.count) objects in the old shared Storj account are already in it."
        if plan.kept > 0 {
            text += " \(plan.kept) objects the phone hasn't imported will be kept."
        }
        return text + " This can't be undone."
    }

    static func statusLine(_ backup: BackupService) -> String {
        switch backup.state {
        case .backingUp(let done, let total):
            return total > 0 ? "Backing up \(done) of \(total)…" : "Backing up…"
        case .restoring(let done, let total):
            return total > 0 ? "Restoring \(done) of \(total)…" : "Restoring…"
        case .verifying(let done, let total):
            return total > 0 ? "Checking \(done) of \(total)…" : "Checking backup…"
        case .failed(let message):
            return message
        case .idle:
            guard backup.isEnabled else { return backup.lastBackedUpAt == nil ? "Off" : "Off · \(lastBackedUpText(backup))" }
            return lastBackedUpText(backup)
        }
    }

    private static func lastBackedUpText(_ backup: BackupService) -> String {
        guard let date = backup.lastBackedUpAt else { return "Not backed up yet" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        let when = Date().timeIntervalSince(date) < 60 ? "just now" : relative.localizedString(for: date, relativeTo: Date())
        let pending = backup.pendingCount > 0 && backup.isEnabled ? " · \(backup.pendingCount) changes waiting" : ""
        return "Last backed up \(when)\(pending)"
    }

    private var statusRow: some View {
        HStack(spacing: AmachSpacing.md) {
            Image(systemName: statusIcon)
                .font(.system(size: 14))
                .foregroundStyle(statusColor)
                .frame(width: 28)
            Text(Self.statusLine(backup))
                .font(AmachType.tiny)
                .foregroundStyle(statusColor)
            Spacer()
            if backup.isBusy { ProgressView().tint(Color.amachPrimaryBright) }
        }
        .listRowBackground(Color.amachSurface)
    }

    private var statusIcon: String {
        if case .failed = backup.state { return "exclamationmark.triangle.fill" }
        return backup.isBusy ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
    }

    private var statusColor: Color {
        if case .failed = backup.state { return Color.amachWarning }
        return Color.amachTextSecondary
    }

    private func actionRow(_ title: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AmachSpacing.md) {
                Image(systemName: icon)
                    .foregroundStyle(Color.amachPrimaryBright)
                    .frame(width: 28)
                Text(title)
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
                Spacer()
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .listRowBackground(Color.amachSurface)
    }

    @ViewBuilder
    private var legacyCleanupRows: some View {
        switch backup.legacyCleanup {
        case .unavailable:
            EmptyView()
        case .available:
            actionRow("Remove old copies from Storj", icon: "trash", disabled: backup.isBusy) {
                backup.prepareLegacyCleanup()
            }
        case .checking:
            cleanupNote("Checking your backup before anything is deleted…", busy: true)
        case .ready(let plan):
            if plan.deletable.isEmpty {
                cleanupNote("No old copies to remove.", busy: false)
            } else {
                actionRow("Delete \(plan.deletable.count) old copies from Storj", icon: "trash", disabled: backup.isBusy) {
                    confirmCleanup = plan
                }
            }
        case .deleting(let done, let total):
            cleanupNote("Deleting old copies \(done) of \(total)…", busy: true)
        case .finished(let deleted, let kept):
            cleanupNote(kept > 0 ? "Removed \(deleted) old copies. Kept \(kept) not yet imported." : "Removed \(deleted) old copies.", busy: false)
        case .failed(let message):
            cleanupNote("Old copies weren't removed: \(message)", busy: false)
        }
    }

    private func cleanupNote(_ text: String, busy: Bool) -> some View {
        HStack(spacing: AmachSpacing.md) {
            Image(systemName: "trash")
                .foregroundStyle(Color.amachTextSecondary)
                .frame(width: 28)
            Text(text)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
            Spacer()
            if busy { ProgressView().tint(Color.amachPrimaryBright) }
        }
        .listRowBackground(Color.amachSurface)
    }
}
