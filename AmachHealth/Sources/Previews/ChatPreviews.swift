// ChatPreviews.swift
// AmachHealth

import SwiftUI

// ============================================================
// MARK: - CHAT (Full Screen)
// ============================================================

#Preview("Chat — Empty State ⚪") {
    ChatView()
        .withMockEnvironment()
        .task { @MainActor in
            MockData.healthyUser()
            ChatService.shared.currentSession = ChatSession()
        }
}

#Preview("Chat — Active Conversation 🟢") {
    ChatView()
        .withMockEnvironment()
        .task { @MainActor in
            MockData.healthyUser()
            var session = ChatSession()
            session.messages = MockMessages.conversation
            ChatService.shared.currentSession = session
        }
}

#Preview("Chat — Single Q&A 🟢") {
    ChatView()
        .withMockEnvironment()
        .task { @MainActor in
            MockData.healthyUser()
            var session = ChatSession()
            session.messages = MockMessages.singleQuestion
            ChatService.shared.currentSession = session
        }
}

#Preview("Chat — Needs Attention Context 🔴") {
    ChatView()
        .withMockEnvironment()
        .task { @MainActor in
            MockData.needsAttentionUser()
            ChatService.shared.currentSession = ChatSession()
        }
}


// ============================================================
// MARK: - LUMA HALF-SHEET
// ============================================================

#Preview("Luma Sheet — Empty ⚪") {
    Color.amachBg
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            LumaSheetView()
                .withMockEnvironment()
                .task { @MainActor in
                    MockData.healthyUser()
                    ChatService.shared.currentSession = ChatSession()
                }
        }
        .preferredColorScheme(.dark)
}

#Preview("Luma Sheet — Active Conversation 🟢") {
    Color.amachBg
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            LumaSheetView()
                .withMockEnvironment()
                .task { @MainActor in
                    MockData.healthyUser()
                    var session = ChatSession()
                    session.messages = MockMessages.conversation
                    ChatService.shared.currentSession = session
                }
        }
        .preferredColorScheme(.dark)
}
