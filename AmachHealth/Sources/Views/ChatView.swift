// ChatView.swift
// AmachHealth
//
// Luma AI chat interface — routes through Amach backend → Venice AI

import SwiftUI

struct ChatView: View {
    @StateObject private var chatService = ChatService.shared
    @State private var messageText = ""
    @State private var showingHistory = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    chatHeader
                    Divider().overlay(Color.amachPrimary.opacity(0.12))
                    messageScrollView
                    inputBar
                }
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showingHistory) {
            ChatHistoryView(chatService: chatService)
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.amachPrimary.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.amachPrimaryBright)
                    .shadow(color: Color.amachPrimary.opacity(0.6), radius: 4)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Luma")
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.amachTextPrimary)
                Text("AI health companion")
                    .font(.caption2)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            Spacer()

            HStack(spacing: 16) {
                Button {
                    showingHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.amachTextSecondary)
                }

                Button {
                    withAnimation(.spring(response: 0.3)) {
                        chatService.startNewSession()
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.amachPrimaryBright)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.amachBg)
    }

    // MARK: - Messages

    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if chatService.currentSession.messages.isEmpty {
                        chatEmptyState
                    } else {
                        ForEach(chatService.currentSession.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }

                        if chatService.isSending {
                            typingIndicator
                        }

                        if let err = chatService.error {
                            errorBanner(err)
                        }
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: chatService.currentSession.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: chatService.isSending) { _, isSending in
                if isSending {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var chatEmptyState: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 50)

            ZStack {
                Circle()
                    .fill(Color.amachPrimary.opacity(0.1))
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(Color.amachPrimary.opacity(0.05))
                    .frame(width: 110, height: 110)
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Color.amachPrimaryBright)
                    .shadow(color: Color.amachPrimary.opacity(0.5), radius: 10)
            }

            VStack(spacing: 8) {
                Text("Ask Luma")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.amachTextPrimary)
                Text("Your AI health companion. Ask about your metrics, trends, or get personalized insights.")
                    .font(.subheadline)
                    .foregroundStyle(Color.amachTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 8) {
                ForEach(quickSuggestions, id: \.self) { suggestion in
                    Button {
                        messageText = suggestion
                        Task { await sendMessage() }
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(Color.amachPrimaryBright)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.amachPrimary.opacity(0.1))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.amachPrimary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
            }

            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.amachPrimary.opacity(0.15))
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.amachPrimaryBright)
            }

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.amachTextSecondary)
                        .frame(width: 6, height: 6)
                        .opacity(chatService.isSending ? 1 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.5)
                                .repeatForever()
                                .delay(Double(i) * 0.18),
                            value: chatService.isSending
                        )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.amachSurface)
            .clipShape(
                RoundedRectangle(cornerRadius: 16)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1)
            )

            Spacer()
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(hex: "F87171"))
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.amachTextSecondary)
                .lineLimit(2)
            Spacer()
            Button("Dismiss") { chatService.error = nil }
                .font(.caption)
                .foregroundStyle(Color.amachPrimaryBright)
        }
        .padding(12)
        .background(Color(hex: "F87171").opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "F87171").opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.amachPrimary.opacity(0.08))

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask Luma...", text: $messageText, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.subheadline)
                    .foregroundStyle(Color.amachTextPrimary)
                    .tint(Color.amachPrimaryBright)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.amachSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(
                                inputFocused
                                    ? Color.amachPrimary.opacity(0.5)
                                    : Color.amachPrimary.opacity(0.15),
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
                            .fill(canSend ? Color.amachPrimary : Color.amachSurface)
                            .frame(width: 42, height: 42)
                            .shadow(
                                color: canSend ? Color.amachPrimary.opacity(0.4) : .clear,
                                radius: 8
                            )
                        Image(systemName: chatService.isSending ? "ellipsis" : "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(canSend ? .white : Color.amachTextSecondary)
                    }
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.amachBg)
        }
    }

    // MARK: - Helpers

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !chatService.isSending
    }

    private var quickSuggestions: [String] {
        ["How's my sleep this week?", "Analyze my heart rate trend", "Tips to improve HRV"]
    }

    private func sendMessage() async {
        guard canSend else { return }
        let text = messageText
        messageText = ""
        inputFocused = false
        await chatService.send(text)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 56)
            } else {
                ZStack {
                    Circle()
                        .fill(Color.amachPrimary.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.amachPrimaryBright)
                }
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(isUser ? Color.white : Color.amachTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser
                            ? Color.amachPrimary
                            : Color.amachSurface
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isUser ? Color.clear : Color.amachPrimary.opacity(0.12),
                                lineWidth: 1
                            )
                    )
                    .shadow(
                        color: isUser ? Color.amachPrimary.opacity(0.2) : .clear,
                        radius: 6
                    )

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            if !isUser {
                Spacer(minLength: 56)
            }
        }
    }
}

// MARK: - Chat History View

struct ChatHistoryView: View {
    @ObservedObject var chatService: ChatService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                if chatService.recentSessions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.amachTextSecondary)
                        Text("No history yet")
                            .font(.headline)
                            .foregroundStyle(Color.amachTextSecondary)
                        Text("Past conversations appear here")
                            .font(.subheadline)
                            .foregroundStyle(Color.amachTextSecondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(chatService.recentSessions) { session in
                            Button {
                                chatService.loadSession(session)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.displayTitle)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(Color.amachTextPrimary)
                                        .lineLimit(2)
                                    HStack {
                                        Text("\(session.messages.count) messages")
                                            .font(.caption)
                                            .foregroundStyle(Color.amachTextSecondary)
                                        Spacer()
                                        Text(session.updatedAt, style: .relative)
                                            .font(.caption)
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
            .navigationTitle("Chat History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.amachPrimaryBright)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Preview

#Preview {
    ChatView()
        .preferredColorScheme(.dark)
}
