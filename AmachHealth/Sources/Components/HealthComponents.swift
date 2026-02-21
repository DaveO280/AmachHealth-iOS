// HealthComponents.swift
// AmachHealth
//
// Health-domain UI building blocks used across Dashboard, Trends,
// MetricDetail, HealthSync, and Profile views.
//
// Components:
//   DataSource / AmachSourceBadge  — provenance tag for any metric record
//   AmachHealthScoreRing           — circular progress arc (header + detail)
//   AmachSectionHeader             — uppercase tracking label with optional trailing
//   AmachStatRow                   — horizontal label + value pair
//   AmachConnectionCard            — HealthKit / Wallet status tile

import SwiftUI


// ============================================================
// MARK: - DATA SOURCE
// ============================================================
//
// Represents where a health data point originated.
// Used as metadata on StorageItemCard, MetricDetailView, and
// future bloodwork / DEXA / CGM record cards.

enum DataSource: String, CaseIterable, Identifiable {
    case appleHealth = "Apple Health"
    case bloodwork   = "Bloodwork"
    case dexa        = "DEXA Scan"
    case cgm         = "CGM"
    case manual      = "Manual Entry"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appleHealth: return "heart.fill"
        case .bloodwork:   return "medical.thermometer.fill"
        case .dexa:        return "figure.stand"
        case .cgm:         return "chart.dots.scatter"
        case .manual:      return "pencil"
        }
    }

    // Source-specific tint — not semantic, not health status
    var tint: Color {
        switch self {
        case .appleHealth: return Color(hex: "EF4444")     // Apple Health red
        case .bloodwork:   return Color.Amach.Semantic.info
        case .dexa:        return Color.Amach.p400
        case .cgm:         return Color.Amach.accent
        case .manual:      return Color.amachTextSecondary
        }
    }
}


// ============================================================
// MARK: - SOURCE BADGE
// ============================================================
//
// Compact provenance tag. Tinted icon + optional label.
// showLabel: false for tight layouts (e.g., inline next to value).
//
// Usage:
//   AmachSourceBadge(.appleHealth)
//   AmachSourceBadge(.bloodwork, showLabel: false)

struct AmachSourceBadge: View {
    let source: DataSource
    var showLabel: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: source.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(source.tint)

            if showLabel {
                Text(source.rawValue)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
        .padding(.horizontal, showLabel ? AmachSpacing.sm : 6)
        .padding(.vertical, 4)
        .background(source.tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.xs))
        .overlay(
            RoundedRectangle(cornerRadius: AmachRadius.xs)
                .stroke(source.tint.opacity(0.22), lineWidth: 1)
        )
        .accessibilityLabel("Source: \(source.rawValue)")
    }
}


// ============================================================
// MARK: - HEALTH SCORE RING
// ============================================================
//
// Circular progress arc showing completeness score (0–100) with
// optional tier letter in the center.
//
// size:      total frame diameter
// lineWidth: stroke width (scales proportionally with size)
//
// Usage (header, 64pt):
//   AmachHealthScoreRing(score: 82, tier: "GOLD")
//
// Usage (profile section, 96pt):
//   AmachHealthScoreRing(score: 82, tier: "SILVER", size: 96, lineWidth: 7)

struct AmachHealthScoreRing: View {
    let score: Int           // 0–100
    let tier: String?        // "GOLD" | "SILVER" | "BRONZE" | "NONE" | nil
    var size: CGFloat   = 64
    var lineWidth: CGFloat = 5

    private var progress: Double {
        Double(min(max(score, 0), 100)) / 100.0
    }

    private var tierLetter: String? {
        guard let t = tier, t.uppercased() != "NONE", !t.isEmpty else { return nil }
        return String(t.prefix(1))
    }

    private var tierColor: Color {
        switch tier?.uppercased() {
        case "GOLD":   return Color.amachAccent
        case "SILVER": return Color.amachSilver
        case "BRONZE": return Color.amachBronze
        default:       return Color.amachTextSecondary
        }
    }

    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(Color.amachPrimary.opacity(0.12), lineWidth: lineWidth)

            // Progress arc — animated on change
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.amachPrimaryBright,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: Color.amachPrimary.opacity(0.40), radius: 6)
                .animation(AmachAnimation.ifMotion(AmachAnimation.chartDraw), value: score)

            // Center content
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: size * 0.25, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.amachTextPrimary)
                    .contentTransition(.numericText())

                if let letter = tierLetter {
                    Text(letter)
                        .font(.system(size: size * 0.14, weight: .bold))
                        .foregroundStyle(tierColor)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Health data score: \(score) out of 100\(tier.map { ", \($0.capitalized) tier" } ?? "")")
        .accessibilityValue("\(score) percent")
    }
}

/// No-data state: dashed ring with heart icon.
struct AmachHealthScoreRingEmpty: View {
    var size: CGFloat   = 64
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    Color.amachPrimary.opacity(0.12),
                    style: StrokeStyle(lineWidth: lineWidth, dash: [4, 4])
                )
            Image(systemName: AmachIcon.heartRate)
                .font(.system(size: size * 0.31))
                .foregroundStyle(Color.amachPrimary.opacity(0.28))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("No health score yet")
    }
}


// ============================================================
// MARK: - SECTION HEADER
// ============================================================
//
// Uppercase letter-spaced section label with optional trailing
// content (ProgressView, buttons, etc.).
//
// Matches the "TODAY" / "SOURCES" / "CONNECTED" label pattern.
//
// Usage:
//   AmachSectionHeader("Today")
//   AmachSectionHeader("Trends", isLoading: dashboard.isLoading)
//   AmachSectionHeader("Connected Sources") {
//       Button("Add") { … }
//   }

struct AmachSectionHeader<Trailing: View>: View {
    let title: String
    var isLoading: Bool
    let trailing: Trailing

    init(
        _ title: String,
        isLoading: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.isLoading = isLoading
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: AmachSpacing.sm) {
            Text(title.uppercased())
                .font(AmachType.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(Color.amachTextSecondary)
                .tracking(1.5)

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(Color.amachPrimaryBright)
            }

            trailing
        }
    }
}


// ============================================================
// MARK: - STAT ROW
// ============================================================
//
// Horizontal label + value row for detail and profile views.
// Supports plain String values or any SwiftUI View as the value.
//
// Usage (plain text):
//   AmachStatRow("Metrics synced", value: "142")
//
// Usage (badge):
//   AmachStatRow("Tier") { AmachTierBadge(tier: "GOLD") }

struct AmachStatRow<ValueContent: View>: View {
    let label: String
    @ViewBuilder let value: () -> ValueContent

    var body: some View {
        HStack {
            Text(label)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
            Spacer()
            value()
        }
        .padding(.vertical, 3)
    }
}

extension AmachStatRow where ValueContent == Text {
    /// Convenience init for plain-string values.
    init(_ label: String, value: String) {
        self.label = label
        self.value = {
            Text(value)
                .font(AmachType.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Color.amachTextPrimary)
                .monospacedDigit()
        }
    }
}


// ============================================================
// MARK: - CONNECTION STATUS CARD
// ============================================================
//
// Displays the connection state for HealthKit or Wallet.
// Used in HealthSyncView (side-by-side pair) and ProfileView.
//
// Usage:
//   AmachConnectionCard(
//       title: "Apple Health",
//       subtitle: "Activity, sleep & vitals",
//       icon: "heart.fill",
//       status: healthKit.isAuthorized ? .connected : .disconnected,
//       actionLabel: "Authorize",
//       action: { Task { try? await healthKit.requestAuthorization() } }
//   )

struct AmachConnectionCard: View {

    enum Status {
        case connected
        case disconnected
        case pending

        var statusIcon: String {
            switch self {
            case .connected:    return "checkmark.circle.fill"
            case .disconnected: return "xmark.circle.fill"
            case .pending:      return "clock.fill"
            }
        }

        var color: Color {
            switch self {
            case .connected:    return Color.Amach.Semantic.success
            case .disconnected: return Color.Amach.Semantic.error
            case .pending:      return Color.Amach.Semantic.warning
            }
        }

        var label: String {
            switch self {
            case .connected:    return "Connected"
            case .disconnected: return "Not Connected"
            case .pending:      return "Pending"
            }
        }
    }

    let title: String
    let subtitle: String
    let icon: String
    let status: Status
    var actionLabel: String = "Connect"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.md) {

            // Icon + label row
            HStack(spacing: AmachSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(
                        status == .connected ? Color.amachPrimary : Color.amachTextSecondary
                    )
                    .frame(width: 36, height: 36)
                    .background(
                        (status == .connected ? Color.amachPrimary : Color.amachTextSecondary)
                            .opacity(0.10)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AmachType.h3)
                        .foregroundStyle(Color.amachTextPrimary)
                    Text(subtitle)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }

                Spacer()
            }

            // Status pill
            HStack(spacing: 4) {
                Image(systemName: status.statusIcon)
                    .font(.system(size: 11))
                    .foregroundStyle(status.color)
                Text(status.label)
                    .font(AmachType.tiny)
                    .fontWeight(.medium)
                    .foregroundStyle(status.color)
            }
            .padding(.horizontal, AmachSpacing.sm)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.10))
            .clipShape(Capsule())

            // Action button — only shown when not connected
            if status != .connected, let action {
                Button(actionLabel, action: action)
                    .amachPrimaryButtonStyle()
            }
        }
        .padding(AmachSpacing.md)
        .amachCard()
    }
}


// ============================================================
// MARK: - PREVIEWS
// ============================================================

#Preview("Source Badges") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            ForEach(DataSource.allCases) { source in
                HStack(spacing: AmachSpacing.sm) {
                    AmachSourceBadge(source)
                    AmachSourceBadge(source, showLabel: false)
                }
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Score Rings") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.xl) {
            HStack(spacing: AmachSpacing.xl) {
                AmachHealthScoreRing(score: 82, tier: "GOLD")
                AmachHealthScoreRing(score: 61, tier: "SILVER", size: 80, lineWidth: 6)
                AmachHealthScoreRing(score: 43, tier: "BRONZE", size: 96, lineWidth: 7)
                AmachHealthScoreRingEmpty()
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Section Headers") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.xl) {
            AmachSectionHeader("Today", isLoading: false)
            AmachSectionHeader("Syncing", isLoading: true)
            AmachSectionHeader("Connected Sources") {
                Button("Manage") {}
                    .amachTertiaryButtonStyle()
            }
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Stat Rows") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: 0) {
            AmachStatRow("Metrics synced", value: "142")
            Divider().padding(.leading)
            AmachStatRow("Days covered", value: "30")
            Divider().padding(.leading)
            AmachStatRow("Tier") { AmachTierBadge(tier: "GOLD") }
        }
        .padding()
        .amachCard()
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Connection Cards") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.md) {
            AmachConnectionCard(
                title: "Apple Health",
                subtitle: "Activity, sleep & vitals",
                icon: AmachIcon.appleHealth,
                status: .connected
            )
            AmachConnectionCard(
                title: "Wallet",
                subtitle: "ZKsync Era · encrypted vault",
                icon: AmachIcon.wallet,
                status: .disconnected,
                actionLabel: "Connect Wallet",
                action: {}
            )
            AmachConnectionCard(
                title: "Storj",
                subtitle: "Encrypted cloud storage",
                icon: AmachIcon.storage,
                status: .pending
            )
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}
