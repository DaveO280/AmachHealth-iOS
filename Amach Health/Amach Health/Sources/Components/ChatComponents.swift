// ChatComponents.swift
// AmachHealth
//
// Standalone chat UI building blocks extracted from LumaSheetView,
// plus new components for richer Luma interactions.
//
// Components:
//   SuggestedPromptChip    — tappable quick-start prompt for Luma empty state
//   PromptSuggestionGrid   — vertical stack of SuggestedPromptChips
//   InlineMetricReference  — tappable metric chip embedded below a Luma message
//
// Designer's Intent:
//   Prompt chips lower the activation energy for starting a conversation.
//   Inline metric references make Luma's answers navigable — a mention of
//   "heart rate" becomes a one-tap shortcut to the full trend view.

import SwiftUI


// ============================================================
// MARK: - SUGGESTED PROMPT CHIP
// ============================================================
//
// A full-width chip showing a pre-written suggestion.
// Tapping fires the prompt immediately into Luma.
//
// Indigo tint — Luma-only, consistent with the rest of the chat UI.
//
// Usage:
//   SuggestedPromptChip("How's my heart health looking?") {
//       Task { await chatService.sendStreaming($0) }
//   }

struct SuggestedPromptChip: View {
    let prompt: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AmachSpacing.sm) {
                Text(prompt)
                    .font(AmachType.caption)
                    .foregroundStyle(Color.Amach.AI.p400)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Amach.AI.base.opacity(0.55))
            }
            .padding(.horizontal, AmachSpacing.md)
            .padding(.vertical, AmachSpacing.sm + 2)
            .background(Color.Amach.AI.base.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AmachRadius.sm)
                    .stroke(Color.Amach.AI.base.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: AmachAccessibility.minTouchTarget)
        .accessibilityLabel("Suggested prompt: \(prompt)")
        .accessibilityHint("Double-tap to send this message to Luma")
    }
}


// ============================================================
// MARK: - PROMPT SUGGESTION GRID
// ============================================================
//
// Vertical stack of SuggestedPromptChips shown on Luma's empty state.
// Context-aware: different prompts for Dashboard vs Trends vs Metric.
//
// Usage (in LumaSheetView empty state):
//   PromptSuggestionGrid(
//       prompts: PromptSuggestionGrid.prompts(for: "Dashboard"),
//       onSelect: { prompt in Task { await chatService.sendStreaming(prompt) } }
//   )

struct PromptSuggestionGrid: View {
    let prompts: [String]
    let onSelect: (String) -> Void

    init(
        prompts: [String] = PromptSuggestionGrid.defaultPrompts,
        onSelect: @escaping (String) -> Void
    ) {
        self.prompts = prompts
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: AmachSpacing.sm) {
            ForEach(prompts, id: \.self) { prompt in
                SuggestedPromptChip(prompt: prompt) {
                    AmachHaptics.cardTap()
                    onSelect(prompt)
                }
            }
        }
    }

    // MARK: Prompt Libraries

    /// Generic fallback prompts — shown on Dashboard and unknown screens.
    static let defaultPrompts: [String] = [
        "How's my heart health looking?",
        "What should I focus on this week?",
        "Explain my sleep patterns",
        "Am I showing any concerning trends?",
    ]

    /// Returns context-aware prompts based on the current screen + metric.
    /// Falls back to defaultPrompts for unrecognized screens.
    static func prompts(for screen: String, metric: String? = nil) -> [String] {
        if let metric = metric {
            return [
                "What's a good \(metric) for someone my age?",
                "Explain what this \(metric) trend means",
                "What can I do to improve my \(metric)?",
            ]
        }
        switch screen {
        case "Dashboard":
            return defaultPrompts
        case "Trends":
            return [
                "What patterns do you see in my data?",
                "What week was my best recovery?",
                "Which metrics need the most attention?",
            ]
        case "HealthSync":
            return [
                "What does my data score mean?",
                "How do I reach Gold tier?",
                "What metrics are missing from my data?",
            ]
        case "Profile":
            return [
                "What does my attestation tier mean?",
                "How does Amach protect my data?",
                "What health metrics matter most long-term?",
            ]
        default:
            return defaultPrompts
        }
    }
}


// ============================================================
// MARK: - INLINE METRIC REFERENCE
// ============================================================
//
// A tappable chip representing a specific health metric.
// Intended to appear below Luma messages when she references
// a metric — tapping navigates to MetricDetailView.
//
// Design notes:
//   - Uses the metric's own color (not indigo — this chip is data,
//     not Luma's UI chrome, even though Luma placed it there)
//   - Shows icon + label + latest value so the user doesn't need
//     to navigate just to see the number
//   - chevron.right signals navigability
//
// Usage (below a LumaMessageBubble):
//   InlineMetricReference(metric: stepsMetric) { tapped in
//       selectedMetric = tapped
//   }

struct InlineMetricReference: View {
    let metric: MetricInfo
    var onTap: ((MetricInfo) -> Void)? = nil

    @State private var isPressed = false

    var body: some View {
        Button {
            AmachHaptics.cardTap()
            onTap?(metric)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: metric.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(metric.color)

                Text(metric.label)
                    .font(AmachType.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.amachTextPrimary)

                if metric.rawValue > 0 {
                    Text("·")
                        .foregroundStyle(Color.amachTextTertiary)
                    Text(metric.value)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(metric.color)
                    if !metric.unit.isEmpty {
                        Text(metric.unit)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.amachTextTertiary)
            }
            .padding(.horizontal, AmachSpacing.sm + 2)
            .padding(.vertical, 5)
            .background(metric.color.opacity(0.08))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(metric.color.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(AmachAnimation.ifMotion(AmachAnimation.spring), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel("\(metric.label): \(metric.value) \(metric.unit)")
        .accessibilityHint("Double-tap to view full metric details")
        .accessibilityAddTraits(.isLink)
    }
}

/// A horizontal scroll of multiple metric reference chips.
/// Use when a Luma message references more than one metric.
struct MetricReferenceRow: View {
    let metrics: [MetricInfo]
    var onTap: ((MetricInfo) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AmachSpacing.sm) {
                ForEach(metrics, id: \.id) { metric in
                    InlineMetricReference(metric: metric, onTap: onTap)
                }
            }
            .padding(.horizontal, AmachSpacing.xs)
        }
    }
}


// ============================================================
// MARK: - PREVIEWS
// ============================================================

#Preview("Prompt Chips") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.md) {
            PromptSuggestionGrid(onSelect: { _ in })
            Divider().padding(.horizontal)
            PromptSuggestionGrid(
                prompts: PromptSuggestionGrid.prompts(for: "Trends"),
                onSelect: { _ in }
            )
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Inline Metric References") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(alignment: .leading, spacing: AmachSpacing.md) {
            // Simulate a Luma message with metric references below it
            VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                Text("Your HRV is looking strong today — one of the best signals for recovery capacity.")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
                    .padding(12)
                    .background(Color.Amach.AI.dark)
                    .clipShape(RoundedRectangle(cornerRadius: AmachRadius.lg))

                MetricReferenceRow(
                    metrics: [
                        .hrv(62),
                        .heartRate(58),
                        .sleep(7.5),
                    ],
                    onTap: { _ in }
                )
            }
            .padding(.horizontal)
        }
    }
    .preferredColorScheme(.dark)
}
