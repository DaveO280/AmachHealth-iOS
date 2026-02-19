// ChatService.swift
// AmachHealth
//
// Manages Cosaint AI chat sessions:
// - Real-time message state
// - Local persistence (documents directory JSON)
// - Batched Storj saves when sessions grow (every 10 messages) or on new session

import Foundation
import Combine

@MainActor
final class ChatService: ObservableObject {
    static let shared = ChatService()

    @Published var currentSession = ChatSession()
    @Published var recentSessions: [ChatSession] = []
    @Published var isSending = false
    @Published var error: String?

    private let api = AmachAPIClient.shared
    private let wallet = WalletService.shared

    private var localStorageURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("amach_chat_sessions.json")
    }

    private init() {
        loadFromDisk()
    }

    // MARK: - Send Message

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMsg = ChatMessage(role: .user, content: trimmed)
        currentSession.messages.append(userMsg)
        currentSession.updatedAt = .now
        saveToDisk()

        isSending = true
        error = nil

        do {
            // Send last 18 messages as history (9 exchanges, keeps context tight)
            let history = currentSession.messages
                .dropLast()
                .suffix(18)
                .map { AIChatHistoryMessage(role: $0.role.rawValue, content: $0.content) }

            let response = try await api.sendChatMessage(trimmed, history: Array(history))

            let assistantMsg = ChatMessage(role: .assistant, content: response.content)
            currentSession.messages.append(assistantMsg)
            currentSession.updatedAt = .now
            saveToDisk()

            // Every 10 messages, batch-save to Storj and clean local copy
            if currentSession.messages.count % 10 == 0 {
                Task { await syncToStorj() }
            }
        } catch {
            self.error = error.localizedDescription
        }

        isSending = false
    }

    // MARK: - Session Management

    func startNewSession() {
        guard !currentSession.messages.isEmpty else { return }

        // Archive current to recent sessions
        recentSessions.insert(currentSession, at: 0)
        if recentSessions.count > 30 {
            recentSessions = Array(recentSessions.prefix(30))
        }
        saveToDisk()

        // Save the archived session to Storj in background
        Task { await syncToStorj(session: currentSession) }

        currentSession = ChatSession()
    }

    func loadSession(_ session: ChatSession) {
        currentSession = session
    }

    // MARK: - Persistence

    private func saveToDisk() {
        // Update current session in the recent list if it's already there
        if let idx = recentSessions.firstIndex(where: { $0.id == currentSession.id }) {
            recentSessions[idx] = currentSession
        }
        let all = [currentSession] + recentSessions.filter { $0.id != currentSession.id }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: localStorageURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard
            let data = try? Data(contentsOf: localStorageURL),
            let sessions = try? JSONDecoder().decode([ChatSession].self, from: data),
            !sessions.isEmpty
        else { return }

        // First entry is the active session, rest are history
        currentSession = sessions[0]
        recentSessions = Array(sessions.dropFirst())
    }

    // MARK: - Storj Sync

    private func syncToStorj(session: ChatSession? = nil) async {
        let target = session ?? currentSession
        guard !target.messages.isEmpty else { return }
        guard wallet.isConnected, let key = wallet.encryptionKey else { return }

        do {
            let uri = try await api.storeChatSession(
                target,
                walletAddress: key.walletAddress,
                encryptionKey: key
            )
            // Update storjUri on current session if we synced the current one
            if target.id == currentSession.id {
                currentSession.storjUri = uri
                saveToDisk()
            }
        } catch {
            // Non-critical — local copy is intact, will retry next cycle
            print("⚠️ ChatService: Storj sync failed: \(error.localizedDescription)")
        }
    }
}
