// ChatView.swift
// AmachHealth
//
// Full-screen Luma AI chat — reached by expanding the Luma half-sheet
// or via deep link. This is the dedicated Luma conversation space.
//
// Design decisions:
//   • Indigo family for all Luma elements (#6366F1 AI.base)
//   • User messages: emerald bubble (amachPrimary)
//   • Luma messages: deep indigo bubble (AI.dark #3730A3)
//   • Context bar shows what data Luma has access to
//   • Medical disclaimer: persistent inline text, not a popup
//   • Chat history: preserved locally + synced to Storj in batches

import SwiftUI

struct ChatView: View {
    @StateObject private var chatService = ChatService.shared
    @EnvironmentObject private var healthKit: HealthKitService
    @ObservedObject private var lumaContext = LumaContextService.shared

    @State private var messageText = ""
    @State private var showingHistory = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    chatHeader
                    Divider().overlay(Color.Amach.AI.base.opacity(0.15))
                    LumaDataContextBar()
                        .environmentObject(healthKit)
                    Divider().overlay(Color.amachPrimary.opacity(0.06))
                    messageScrollView
                    inputBar
                }
            }
            .navigationBarHidden(true)
            .onAppear { lumaContext.update(screen: "Chat") }
        }
        .sheet(isPresented: $showingHistory) {
            ChatHistoryView(chatService: chatService)
        }
    }

    // ============================================================
    // MARK: - Header
    // ============================================================

    private var chatHeader: some View {
        HStack(spacing: AmachSpacing.sm) {
            // Luma avatar
            ZStack {
                Circle()
                    .fill(Color.Amach.AI.base.opacity(0.16))
                    .frame(width: 40, height: 40)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.Amach.AI.p400)
                    .shadow(color: Color.Amach.AI.base.opacity(0.5), radius: 4)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Luma")
                        .font(AmachType.h3)
                        .foregroundStyle(Color.amachTextPrimary)
                    // Online indicator
                    Circle()
                        .fill(Color.amachSuccess)
                        .frame(width: 6, height: 6)
                }
                Text("AI health companion · Not medical advice")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.amachTextTertiary)
            }

            Spacer()

            HStack(spacing: AmachSpacing.md) {
                Button {
                    showingHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.amachTextSecondary)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("View chat history")

                Button {
                    withAnimation(AmachAnimation.spring) {
                        chatService.startNewSession()
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.Amach.AI.p400)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Start new conversation")
            }
        }
        .padding(.horizontal, AmachSpacing.md)
        .padding(.vertical, AmachSpacing.sm + 2)
        .background(Color.amachBg)
    }

    // ============================================================
    // MARK: - Messages
    // ============================================================

    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: AmachSpacing.sm) {
                    if chatService.currentSession.messages.isEmpty {
                        chatEmptyState
                    } else {
                        ForEach(chatService.currentSession.messages) { msg in
                            LumaMessageBubble(message: msg)
                                .id(msg.id)
                        }

                        if chatService.isSending {
                            LumaTypingBubble()
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        }

                        if let err = chatService.error {
                            errorBanner(err)
                        }
                    }

                    Color.clear.frame(height: 4).id("chatBottom")
                }
                .padding(.horizontal, AmachSpacing.md)
                .padding(.vertical, AmachSpacing.md)
            }
            .onChange(of: chatService.currentSession.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                }
            }
            .onChange(of: chatService.isSending) { _, isSending in
                if isSending {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("chatBottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // ============================================================
    // MARK: - Empty State
    // ============================================================

    private var chatEmptyState: some View {
        VStack(spacing: AmachSpacing.xl) {
            Spacer(minLength: AmachSpacing.xl)

            // Luma icon
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
                    .shadow(color: Color.Amach.AI.base.opacity(0.4), radius: 14)
            }

            VStack(spacing: AmachSpacing.sm) {
                Text("Ask Luma")
                    .font(AmachType.h1)
                    .foregroundStyle(Color.amachTextPrimary)
                Text("Ask about your metrics, trends, or what\nto focus on. Luma reads your data, not\ngeneric health advice.")
                    .font(AmachType.body)
                    .foregroundStyle(Color.amachTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, AmachSpacing.md)
            }

            // Suggested prompts — indigo chip style
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
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.Amach.AI.base.opacity(0.5))
                        }
                        .padding(.horizontal, AmachSpacing.md)
                        .padding(.vertical, AmachSpacing.sm + 2)
                        .background(Color.Amach.AI.base.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AmachRadius.sm)
                                .stroke(Color.Amach.AI.base.opacity(0.16), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, AmachSpacing.md)

            // Disclaimer
            HStack(spacing: AmachSpacing.xs) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Luma offers insights, not medical advice. Always consult a healthcare provider for medical decisions.")
                    .font(.system(size: 10))
                    .lineSpacing(2)
            }
            .foregroundStyle(Color.amachTextTertiary)
            .padding(.horizontal, AmachSpacing.xl)
            .multilineTextAlignment(.center)

            Spacer(minLength: AmachSpacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    // ============================================================
    // MARK: - Error Banner
    // ============================================================

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: AmachSpacing.sm) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.amachDestructive)
                .font(AmachType.caption)
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

    // ============================================================
    // MARK: - Input Bar
    // ============================================================

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.Amach.AI.base.opacity(0.10))

            HStack(alignment: .bottom, spacing: AmachSpacing.sm) {
                TextField("Ask Luma…", text: $messageText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(AmachType.body)
                    .foregroundStyle(Color.amachTextPrimary)
                    .tint(Color.Amach.AI.p400)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.amachSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(
                                inputFocused
                                    ? Color.Amach.AI.base.opacity(0.5)
                                    : Color.Amach.AI.base.opacity(0.15),
                                lineWidth: 1
                            )
                    )
                    .focused($inputFocused)
                    .onSubmit { Task { await sendMessage() } }

                // Send button — indigo
                Button {
                    Task { await sendMessage() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                canSend
                                    ? LinearGradient(
                                        colors: [Color.Amach.AI.base, Color(hex: "4338CA")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    : LinearGradient(
                                        colors: [Color.amachSurface, Color.amachSurface],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                            )
                            .frame(width: 42, height: 42)
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
                .accessibilityLabel(chatService.isSending ? "Sending" : "Send to Luma")
            }
            .padding(.horizontal, AmachSpacing.md)
            .padding(.vertical, AmachSpacing.sm + 2)
            .background(Color.amachBg)
        }
    }

    // ============================================================
    // MARK: - Helpers
    // ============================================================

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chatService.isSending
    }

    private var quickSuggestions: [String] {
        [
            "How's my heart health looking?",
            "What should I focus on this week?",
            "Explain my sleep patterns",
            "Compare my HRV to last week",
        ]
    }

    private func sendMessage() async {
        guard canSend else { return }
        let text = messageText
        messageText = ""
        inputFocused = false
        AmachHaptics.buttonPress()
        await chatService.send(text)
        AmachHaptics.lumaResponse()
    }
}


// ============================================================
// MARK: - CHAT HISTORY VIEW
// ============================================================

struct ChatHistoryView: View {
    @ObservedObject var chatService: ChatService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                if chatService.recentSessions.isEmpty {
                    emptyHistory
                } else {
                    historyList
                }
            }
            .navigationTitle("Conversations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.Amach.AI.p400)
                        .font(AmachType.caption)
                        .fontWeight(.semibold)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyHistory: some View {
        VStack(spacing: AmachSpacing.md) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(Color.amachTextSecondary.opacity(0.4))
            Text("No past conversations")
                .font(AmachType.h3)
                .foregroundStyle(Color.amachTextSecondary)
            Text("Your conversations with Luma appear here.")
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        List {
            ForEach(chatService.recentSessions) { session in
                Button {
                    chatService.loadSession(session)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.displayTitle)
                            .font(AmachType.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(Color.amachTextPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        HStack {
                            Text("\(session.messages.count) messages")
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.amachTextSecondary)
                            Spacer()
                            Text(session.updatedAt, style: .relative)
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.amachTextSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Color.amachSurface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}


// ============================================================
// MARK: - PREVIEW
// ============================================================

#Preview {
    ChatView()
        .environmentObject(HealthKitService.shared)
        .preferredColorScheme(.dark)
}
