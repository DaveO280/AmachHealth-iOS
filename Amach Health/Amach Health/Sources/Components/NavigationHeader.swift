// NavigationHeader.swift
// AmachHealth
//
// Reusable in-content navigation header used across detail and
// modal screens where .navigationTitle feels too native/generic.
//
// Components:
//   AmachNavigationHeader  — back button + title/subtitle + trailing slot
//   AmachModalHeader       — close button (X) variant for sheets/modals
//
// Designer's Intent:
//   The brand doesn't want plain system NavigationBar chrome.
//   These headers give us full control over typography, spacing,
//   and the emerald color on the back chevron — making even a
//   detail screen feel cohesive with the design system.

import SwiftUI


// ============================================================
// MARK: - AMACH NAVIGATION HEADER
// ============================================================
//
// Used in screens reached via NavigationStack push:
//   MetricDetailView, StorageListView, attestation details.
//
// Usage (no trailing):
//   AmachNavigationHeader("Heart Rate")
//
// Usage (with subtitle):
//   AmachNavigationHeader("Heart Rate", subtitle: "Last 30 days")
//
// Usage (with trailing button):
//   AmachNavigationHeader("Sync History") {
//       Button { shareAction() } label: {
//           Image(systemName: "square.and.arrow.up")
//               .foregroundStyle(Color.amachPrimary)
//       }
//   }

struct AmachNavigationHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?     = nil
    var showBack: Bool        = true
    var backAction: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: AmachSpacing.sm) {

            // ── Back button ──────────────────────────────────
            if showBack {
                Button {
                    AmachHaptics.cardTap()
                    if let custom = backAction { custom() } else { dismiss() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(Color.amachPrimary)
                    .frame(
                        width: AmachAccessibility.minTouchTarget,
                        height: AmachAccessibility.minTouchTarget
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            // ── Title block ──────────────────────────────────
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AmachType.h2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.amachTextPrimary)
                    .tracking(-0.2)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // ── Trailing slot ─────────────────────────────────
            trailing
        }
        .padding(.horizontal, AmachSpacing.md)
        .padding(.vertical, AmachSpacing.sm)
        .frame(minHeight: 52)
    }
}

// Convenience init — no trailing content
extension AmachNavigationHeader where Trailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        showBack: Bool = true,
        backAction: (() -> Void)? = nil
    ) {
        self.title      = title
        self.subtitle   = subtitle
        self.showBack   = showBack
        self.backAction = backAction
        self.trailing   = EmptyView()
    }
}


// ============================================================
// MARK: - AMACH MODAL HEADER
// ============================================================
//
// Used in sheet / modal presentations where "Back" makes no
// semantic sense — replaced with an X dismiss button.
//
// Luma-aware: when lumaColors = true, the title and X use
// indigo instead of emerald (for ChatView / Luma full-screen).
//
// Usage (standard modal):
//   AmachModalHeader("Stored Data")
//
// Usage (Luma full-screen):
//   AmachModalHeader("Luma", lumaColors: true) {
//       Button { newSession() } label: {
//           Image(systemName: "square.and.pencil")
//       }
//   }

struct AmachModalHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?    = nil
    var lumaColors: Bool     = false
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing

    @Environment(\.dismiss) private var dismiss

    private var accentColor: Color {
        lumaColors ? Color.Amach.AI.p400 : Color.amachPrimary
    }

    var body: some View {
        HStack(spacing: AmachSpacing.sm) {

            // ── Title block ──────────────────────────────────
            VStack(alignment: .leading, spacing: 1) {
                if lumaColors {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(accentColor)
                        Text(title)
                            .font(AmachType.h2)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.amachTextPrimary)
                    }
                } else {
                    Text(title)
                        .font(AmachType.h2)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.amachTextPrimary)
                        .tracking(-0.2)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }

            Spacer()

            // ── Trailing slot ─────────────────────────────────
            trailing

            // ── Dismiss (X) button ────────────────────────────
            Button {
                AmachHaptics.cardTap()
                if let custom = onDismiss { custom() } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.amachTextSecondary)
                    .frame(
                        width: AmachAccessibility.minTouchTarget,
                        height: AmachAccessibility.minTouchTarget
                    )
                    .background(Color.amachSurface)
                    .clipShape(Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, AmachSpacing.md)
        .padding(.vertical, AmachSpacing.sm)
        .frame(minHeight: 52)
    }
}

// Convenience init — no trailing content
extension AmachModalHeader where Trailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        lumaColors: Bool = false,
        onDismiss: (() -> Void)? = nil
    ) {
        self.title      = title
        self.subtitle   = subtitle
        self.lumaColors = lumaColors
        self.onDismiss  = onDismiss
        self.trailing   = EmptyView()
    }
}


// ============================================================
// MARK: - PREVIEWS
// ============================================================

#Preview("Navigation Headers") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.xl) {
            // Push navigation header — no trailing
            AmachNavigationHeader("Heart Rate", subtitle: "Last 30 days")
                .amachCard()

            // Push navigation header — with trailing icon
            AmachNavigationHeader("Sync History") {
                Button {} label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.amachPrimary)
                        .frame(width: 44, height: 44)
                }
            }
            .amachCard()

            // Modal header — standard dismiss
            AmachModalHeader("Stored Data")
                .amachCard()

            // Modal header — Luma colors + trailing button
            AmachModalHeader("Luma", subtitle: "AI health companion", lumaColors: true) {
                Button {} label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.Amach.AI.p400)
                        .frame(width: 44, height: 44)
                }
            }
            .amachCard()
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
