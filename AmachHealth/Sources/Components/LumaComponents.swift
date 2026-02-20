// LumaComponents.swift
// AmachHealth
//
// Luma persistent UI system:
//   LumaContextService  — observable context shared across all screens
//   LumaFABButton       — floating action button (sparkles, indigo)
//   LumaHalfSheetView   — half-sheet chat drawer (medium → full detent)
//   LumaInsightCard     — proactive insight card for Dashboard
//   LumaContextBar      — data-access indicator shown in full chat
//
// Design rules:
//   • Indigo color family (#6366F1) is LUMA-ONLY. Never on user elements.
//   • FAB lives in ContentView overlay — visible on all tabs except full chat.
//   • HalfSheet uses native iOS sheet detents (.fraction(0.6) + .large).
//   • InsightCard uses emerald→indigo gradient border (AI signal).

import SwiftUI

// ============================================================
// MARK: - LUMA CONTEXT SERVICE
// ============================================================
// Single observable that tracks what the user is currently
// looking at, so Luma can reference it without the user having
// to explain. Updated by each screen on appear.

@MainActor
final class LumaContextService: ObservableObject {
    static let shared = LumaContextService()

    @Published var currentScreen: String = "Dashboard"
    @Published var currentMetric: String? = nil
    @Published var hasUnread: Bool = false

    private init() {}

    func update(screen: String, metric: String? = nil) {
        currentScreen = screen
        currentMetric = metric
    }

    func markRead() {
        hasUnread = false
    }

    var contextSummary: String {
        if let metric = currentMetric {
            return "Viewing \(metric) on \(currentScreen)"
        }
        return "Viewing \(currentScreen)"
    }
}


// ============================================================
// MARK: - LUMA FAB BUTTON
// ============================================================
// 56×56pt indigo circle with sparkles icon.
// Unread dot: 10pt emerald circle at top-trailing.
// Spring scale on press. Indigo ambient glow.

struct LumaFABButton: View {
    let hasUnread: Bool
    let action: () -> Void

    @State private var isPressed = false
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        Button(action: {
            AmachHaptics.buttonPress()
            action()
        }) {
            ZStack(alignment: .topTrailing) {
                // Glow ring (pulse when unread)
                Circle()
                    .fill(Color.Amach.AI.base.opacity(0.15))
                    .frame(width: 72, height: 72)
                    .scaleEffect(pulseScale)
                    .opacity(hasUnread ? 1 : 0)

                // Main FAB circle
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.Amach.AI.p400, Color(hex: "4338CA")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .shadow(
                        color: Color.Amach.AI.base.opacity(0.45),
                        radius: 14, x: 0, y: 6
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )

                // Sparkles icon
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .shadow(color: Color.white.opacity(0.3), radius: 4)

                // Unread indicator dot
                if hasUnread {
                    Circle()
                        .fill(Color.amachPrimaryBright)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color(hex: "0A1A15"), lineWidth: 2)
                        )
                        .offset(x: 8, y: -8)
                }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.90 : 1.0)
        .animation(AmachAnimation.ifMotion(AmachAnimation.spring), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel("Luma AI companion")
        .accessibilityHint(hasUnread ? "Luma has a new insight. Double-tap to open." : "Double-tap to ask Luma about your health.")
        .onAppear {
            guard hasUnread, !UIAccessibility.isReduceMotionEnabled else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulseScale = 1.25
            }
        }
        .onChange(of: hasUnread) { _, newValue in
            if newValue && !UIAccessibility.isReduceMotionEnabled {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulseScale = 1.25
                }
            } else {
                pulseScale = 1.0
            }
        }
    }
}


// ============================================================
// MARK: - LUMA HALF-SHEET / FULL CHAT VIEW
// ============================================================
// Presented as a sheet with two detents:
//   .fraction(0.6) → half-sheet (quick access, suggestions)
//   .large          → full Luma chat (same ChatService)
//
// Context bar at top shows what data Luma has access to.
// Medical disclaimer is persistent (inline, not a popup).

struct LumaSheetView: View {
    @ObservedObject private var chatService = ChatService.shared
    @ObservedObject private var lumaContext = LumaContextService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var messageText = ""
    @State private var selectedDetent: PresentationDetent = .fraction(0.6)
    @FocusState private var inputFocused: Bool

    private var isFullScreen: Bool { selectedDetent == .large }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Context bar — always visible
                    contextBar

                    Divider()
                        .overlay(Color.Amach.AI.base.opacity(0.15))

                    // Messages or empty state
                    messageArea

                    // Input bar
                    inputBar
                }
            }
            .navigationBarHidden(true)
        }
        .presentationDetents([.fraction(0.6), .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
        .presentationBackground(Color.amachBg)
        .presentationCornerRadius(AmachRadius.xl)
        .onAppear { lumaContext.markRead() }
    }

    // MARK: Context Bar

    private var contextBar: some View {
        HStack(spacing: 12) {
            // Luma avatar
            ZStack {
                Circle()
                    .fill(Color.Amach.AI.base.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.Amach.AI.p400)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Luma")
                        .font(AmachType.h3)
                        .foregroundStyle(Color.amachTextPrimary)

                    // Online dot
                    Circle()
                        .fill(Color.amachSuccess)
                        .frame(width: 6, height: 6)
                }
                Text(lumaContext.contextSummary)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            Spacer()

            // Expand / collapse button
            Button {
                withAnimation(AmachAnimation.sheetSpring) {
                    selectedDetent = isFullScreen ? .fraction(0.6) : .large
                }
            } label: {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.amachTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.amachSurface)
                    .clipShape(Circle())
            }
            .accessibilityLabel(isFullScreen ? "Collapse Luma" : "Expand Luma to full screen")

            // New session
            Button {
                withAnimation(AmachAnimation.spring) {
                    chatService.startNewSession()
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.amachTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.amachSurface)
                    .clipShape(Circle())
            }
            .accessibilityLabel("Start new conversation")
        }
        .padding(.horizontal, AmachSpacing.md)
        .padding(.vertical, AmachSpacing.sm)
    }

    // MARK: Message Area

    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if chatService.currentSession.messages.isEmpty {
                        lumaEmptyState
                    } else {
                        ForEach(chatService.currentSession.messages) { msg in
                            LumaMessageBubble(message: msg)
                                .id(msg.id)
                        }

                        if chatService.isSending {
                            LumaTypingBubble()
                        }

                        if let err = chatService.error {
                            lumaErrorBanner(err)
                        }
                    }

                    Color.clear.frame(height: 4).id("lumaBottom")
                }
                .padding(.horizontal, AmachSpacing.md)
                .padding(.vertical, AmachSpacing.sm)
            }
            .onChange(of: chatService.currentSession.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("lumaBottom", anchor: .bottom)
                }
            }
            .onChange(of: chatService.isSending) { _, isSending in
                if isSending {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("lumaBottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: Empty State

    private var lumaEmptyState: some View {
        VStack(spacing: AmachSpacing.lg) {
            Spacer(minLength: AmachSpacing.lg)

            // Animated Luma icon
            ZStack {
                Circle()
                    .fill(Color.Amach.AI.base.opacity(0.08))
                    .frame(width: 96, height: 96)
                Circle()
                    .fill(Color.Amach.AI.base.opacity(0.04))
                    .frame(width: 120, height: 120)
                Image(systemName: "sparkles")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.Amach.AI.p400)
                    .shadow(color: Color.Amach.AI.base.opacity(0.4), radius: 12)
            }

            VStack(spacing: AmachSpacing.sm) {
                Text("Ask Luma")
                    .font(AmachType.h2)
                    .foregroundStyle(Color.amachTextPrimary)
                Text("Your AI health companion. I read your\ndata and find patterns, not prescriptions.")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            // Suggested prompts
            VStack(spacing: AmachSpacing.sm) {
                ForEach(quickSuggestions, id: \.self) { suggestion in
                    Button {
                        messageText = suggestion
                        Task { await sendMessage() }
                    } label: {
                        HStack {
                            Text(suggestion)
                                .font(AmachType.caption)
                                .foregroundStyle(Color.Amach.AI.p400)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.Amach.AI.base.opacity(0.6))
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
                }
            }
            .padding(.horizontal, AmachSpacing.xs)

            // Medical disclaimer
            medicalDisclaimer

            Spacer(minLength: AmachSpacing.md)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AmachSpacing.md)
    }

    // MARK: Medical Disclaimer

    private var medicalDisclaimer: some View {
        HStack(spacing: AmachSpacing.xs) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text("Luma offers insights, not medical advice. Always consult a healthcare provider.")
                .font(.system(size: 10, weight: .regular))
                .lineSpacing(2)
        }
        .foregroundStyle(Color.amachTextTertiary)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, AmachSpacing.md)
        .padding(.vertical, AmachSpacing.sm)
        .background(Color.amachSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
    }

    // MARK: Error Banner

    private func lumaErrorBanner(_ message: String) -> some View {
        HStack(spacing: AmachSpacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.amachDestructive)
                .font(.caption)
            Text(message)
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachTextSecondary)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { chatService.error = nil }
                .font(AmachType.tiny)
                .foregroundStyle(Color.amachPrimaryBright)
        }
        .padding(12)
        .background(Color.amachDestructive.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AmachRadius.sm)
                .stroke(Color.amachDestructive.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.Amach.AI.base.opacity(0.12))

            HStack(alignment: .bottom, spacing: AmachSpacing.sm) {
                TextField("Ask Luma…", text: $messageText, axis: .vertical)
                    .lineLimit(1...4)
                    .font(AmachType.body)
                    .foregroundStyle(Color.amachTextPrimary)
                    .tint(Color.Amach.AI.p400)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.amachSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(
                                inputFocused
                                    ? Color.Amach.AI.base.opacity(0.5)
                                    : Color.Amach.AI.base.opacity(0.15),
                                lineWidth: 1
                            )
                    )
                    .focused($inputFocused)
                    .onSubmit { Task { await sendMessage() } }

                Button {
                    Task { await sendMessage() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(canSend
                                ? LinearGradient(colors: [Color.Amach.AI.base, Color(hex: "4338CA")],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)
                                : LinearGradient(colors: [Color.amachSurface, Color.amachSurface],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 40, height: 40)
                            .shadow(
                                color: canSend ? Color.Amach.AI.base.opacity(0.4) : .clear,
                                radius: 8
                            )
                        Image(systemName: chatService.isSending ? "ellipsis" : "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(canSend ? .white : Color.amachTextSecondary)
                    }
                }
                .disabled(!canSend)
                .accessibilityLabel(chatService.isSending ? "Sending" : "Send message")
            }
            .padding(.horizontal, AmachSpacing.md)
            .padding(.vertical, AmachSpacing.sm + 2)
            .background(Color.amachBg)
        }
        .padding(.bottom, AmachSpacing.sm)
    }

    // MARK: Helpers

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatService.isSending
    }

    private var quickSuggestions: [String] {
        [
            "How's my heart health looking?",
            "What should I focus on this week?",
            "Explain my sleep patterns",
        ]
    }

    private func sendMessage() async {
        guard canSend else { return }
        let text = messageText
        messageText = ""
        inputFocused = false
        // Expand to full if in half-sheet
        if selectedDetent == .fraction(0.6) {
            withAnimation(AmachAnimation.sheetSpring) {
                selectedDetent = .large
            }
        }
        await chatService.send(text)
    }
}


// ============================================================
// MARK: - LUMA MESSAGE BUBBLE
// ============================================================
// Luma messages: indigo dark bubble, white text.
// User messages: emerald bubble, white text.
// Leading flat corner on Luma, trailing flat corner on user.

struct LumaMessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: AmachSpacing.sm) {
            if isUser {
                Spacer(minLength: 56)
            } else {
                // Luma avatar
                ZStack {
                    Circle()
                        .fill(Color.Amach.AI.base.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.Amach.AI.p400)
                }
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(AmachType.body)
                    .foregroundStyle(
                        isUser ? Color.white : Color.amachTextPrimary
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser
                            ? AnyShapeStyle(Color.amachPrimary)
                            : AnyShapeStyle(Color.Amach.AI.dark)
                    )
                    .clipShape(
                        RoundedRectangle(cornerRadius: AmachRadius.lg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AmachRadius.lg)
                            .stroke(
                                isUser
                                    ? Color.clear
                                    : Color.Amach.AI.base.opacity(0.22),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: isUser ? Color.amachPrimary.opacity(0.25) : Color.Amach.AI.base.opacity(0.15),
                        radius: 6, y: 2
                    )

                Text(message.timestamp, style: .time)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextTertiary)
            }

            if !isUser {
                Spacer(minLength: 56)
            }
        }
    }
}


// ============================================================
// MARK: - LUMA TYPING BUBBLE
// ============================================================
// Luma-branded typing indicator in a bubble.

struct LumaTypingBubble: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: AmachSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.Amach.AI.base.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.Amach.AI.p400)
            }

            LumaTypingIndicator()

            Spacer(minLength: 56)
        }
    }
}


// ============================================================
// MARK: - LUMA INSIGHT CARD
// ============================================================
// Proactive insight card shown on Dashboard.
// Emerald→Indigo gradient border signals AI-generated content.
// Sparkles icon in indigo. "Ask Luma" CTA.

struct LumaInsightCard: View {
    let insight: String
    let onAsk: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm + 4) {
            // Header
            HStack(spacing: AmachSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(Color.Amach.AI.base.opacity(0.14))
                        .frame(width: 32, height: 32)
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.Amach.AI.p400)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Luma's Take")
                        .font(AmachType.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Amach.AI.p400)
                        .tracking(0.3)
                    Text("AI insight · Not medical advice")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.amachTextTertiary)
                }

                Spacer()
            }

            // Insight text
            Text(insight)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            // Ask Luma CTA
            Button(action: onAsk) {
                HStack(spacing: AmachSpacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                    Text("Ask Luma")
                        .font(AmachType.tiny)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(Color.Amach.AI.p400)
                .padding(.horizontal, AmachSpacing.sm + 4)
                .padding(.vertical, 6)
                .background(Color.Amach.AI.base.opacity(0.1))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.Amach.AI.base.opacity(0.22), lineWidth: 1)
                )
            }
        }
        .padding(AmachSpacing.lg)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
        .amachAIBorder()
        .shadow(
            color: Color.Amach.AI.base.opacity(0.12),
            radius: 12, y: 4
        )
    }
}


// ============================================================
// MARK: - LUMA CONTEXT BAR (full chat variant)
// ============================================================
// Shown at the top of full-screen Luma chat.
// Lists the data categories Luma has access to.

struct LumaDataContextBar: View {
    @EnvironmentObject private var healthKit: HealthKitService

    private var accessedSources: [String] {
        var sources: [String] = []
        if healthKit.isAuthorized {
            sources += ["Apple Health", "Activity", "Sleep", "Heart"]
        }
        return sources.isEmpty ? ["No data connected"] : sources
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AmachSpacing.sm) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.Amach.AI.base.opacity(0.6))

                ForEach(accessedSources, id: \.self) { source in
                    Text(source)
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.Amach.AI.p400)
                        .padding(.horizontal, AmachSpacing.sm)
                        .padding(.vertical, 3)
                        .background(Color.Amach.AI.base.opacity(0.08))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.Amach.AI.base.opacity(0.15), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, AmachSpacing.md)
            .padding(.vertical, AmachSpacing.sm)
        }
        .background(Color.amachBg)
        .accessibilityLabel("Luma has access to: \(accessedSources.joined(separator: ", "))")
    }
}
