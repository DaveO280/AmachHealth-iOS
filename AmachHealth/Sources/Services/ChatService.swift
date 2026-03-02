// ChatService.swift
// AmachHealth
//
// Manages Luma AI chat sessions:
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

    // MARK: - send() — non-streaming (request/response via /api/ai/chat)
    //
    // Retained for fallback and contexts where streaming isn't needed.
    // For progressive token delivery, use sendStreaming() instead.

    func send(_ text: String, context: AIChatContext? = nil) async {
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

            let response = try await api.sendChatMessage(trimmed, history: Array(history), context: context)

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

    // MARK: - sendStreaming() — progressive token delivery via /api/ai/chat
    //
    // Appends a user message, then an empty assistant placeholder.
    // Tokens arrive progressively and are appended to the placeholder
    // message in-place, triggering real-time UI updates.
    //
    // Designer's Intent:
    //   Word-by-word rendering makes Luma feel alive — like she's
    //   composing the answer in the moment, not retrieving it from
    //   a database. The difference in feel is significant.

    func sendStreaming(_ text: String, context: AIChatContext? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 1. Append user message
        currentSession.messages.append(ChatMessage(role: .user, content: trimmed))
        currentSession.updatedAt = .now

        // 2. Append empty assistant placeholder — tokens fill it in
        currentSession.messages.append(ChatMessage(role: .assistant, content: ""))
        let assistantIdx = currentSession.messages.count - 1

        isSending = true
        error = nil

        // History excludes the current user turn and the placeholder
        let history = currentSession.messages
            .dropLast(2)
            .suffix(18)
            .map { AIChatHistoryMessage(role: $0.role.rawValue, content: $0.content) }

        let screen = LumaContextService.shared.currentScreen
        let metric = LumaContextService.shared.currentMetric

        do {
            let stream = api.streamLumaChat(
                trimmed,
                history: Array(history),
                context: context,
                screen: screen,
                metric: metric
            )

            for try await token in stream {
                currentSession.messages[assistantIdx].content += token
                currentSession.updatedAt = .now
            }

            saveToDisk()
            AmachHaptics.lumaResponse()

            if currentSession.messages.count % 10 == 0 {
                Task { await syncToStorj() }
            }
        } catch {
            // If nothing was streamed, remove the empty placeholder so the
            // UI doesn't show a blank Luma bubble
            if currentSession.messages[assistantIdx].content.isEmpty {
                currentSession.messages.remove(at: assistantIdx)
            }
            self.error = error.localizedDescription
        }

        isSending = false
    }

    // MARK: - Session Management

    func startNewSession() {
        guard !currentSession.messages.isEmpty else { return }

        let sessionToArchive = currentSession

        // Archive current to recent sessions
        recentSessions.insert(sessionToArchive, at: 0)
        if recentSessions.count > 30 {
            recentSessions = Array(recentSessions.prefix(30))
        }
        saveToDisk()

        // Summarize health content and sync to Storj in background
        Task {
            await summarizeAndArchive(sessionToArchive)
            await syncToStorj(session: sessionToArchive)
        }

        currentSession = ChatSession()
    }

    func loadSession(_ session: ChatSession) {
        currentSession = session
    }

    // MARK: - Proactive Insight Delivery

    /// Deliver a Luma-initiated proactive insight into the chat.
    ///
    /// Unlike sendStreaming(), there is no user message — Luma opens the
    /// conversation. The assistant placeholder is tagged as Luma-initiated
    /// so the UI can render it distinctly and the session is linkable back
    /// to the originating HealthEvent.
    func deliverProactiveInsight(_ event: HealthEvent) async {
        // Archive any existing session before starting the proactive one
        if !currentSession.messages.isEmpty {
            startNewSession()
        }

        let service = LumaProactiveService.shared
        let message = service.buildOpeningMessage(for: event)
        let veniceContext = AIChatContext(proactive: service.buildVeniceContext(for: event))

        // Luma-initiated placeholder — no user message above it
        let placeholder = ChatMessage(
            role: .assistant,
            content: "",
            metadata: ChatMessageMetadata(
                triggerType: "proactive_anomaly",
                healthEventId: event.id,
                isLumaInitiated: true
            )
        )
        currentSession.messages.append(placeholder)
        let idx = currentSession.messages.count - 1
        currentSession.updatedAt = .now

        isSending = true
        error = nil

        do {
            let stream = api.streamLumaChat(
                message,
                history: [],
                context: veniceContext,
                screen: "proactive_insight"
            )
            for try await token in stream {
                currentSession.messages[idx].content += token
                currentSession.updatedAt = .now
            }
            saveToDisk()
            AmachHaptics.lumaResponse()
            // Link this session back to the HealthEvent for future memory queries
            service.linkSession(currentSession.id, to: event.id)
        } catch {
            if currentSession.messages[idx].content.isEmpty {
                currentSession.messages.remove(at: idx)
            }
            self.error = error.localizedDescription
        }

        isSending = false
    }

    // MARK: - Proactive Intelligence Support

    /// Whether any of the last 3 sessions substantively discussed a given metric.
    /// Used by LumaProactiveService to avoid surfacing duplicate anomaly notifications.
    func hasRecentDiscussion(about metricType: String) -> Bool {
        let searchTerms = relevantSearchTerms(for: metricType)
        let sessionsToCheck = ([currentSession] + recentSessions.prefix(2))
        for session in sessionsToCheck {
            let allText = session.messages.map { $0.content }.joined(separator: " ").lowercased()
            if searchTerms.contains(where: { allText.contains($0) }) {
                // Only counts if discussion happened in the last 3 days
                let daysSince = Calendar.current.dateComponents(
                    [.day], from: session.updatedAt, to: .now
                ).day ?? 99
                if daysSince <= 3 { return true }
            }
        }
        return false
    }

    /// Summarize a session's health content via Venice and store the result.
    /// Called when archiving a session — the summary feeds future proactive contexts.
    func summarizeAndArchive(_ session: ChatSession) async {
        guard session.messages.count >= 4 else { return }  // skip very short sessions
        guard session.healthSummary == nil else { return }  // already summarized

        let summaryPrompt =
            "In 1-2 sentences, summarize ONLY the health events, anomalies, or symptoms " +
            "discussed in this conversation, and any outcomes mentioned. " +
            "If no health-significant content was discussed, reply with exactly: null"

        let history = session.messages.map {
            AIChatHistoryMessage(role: $0.role.rawValue, content: $0.content)
        }

        do {
            let response = try await api.sendChatMessage(summaryPrompt, history: history)
            let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard summary.lowercased() != "null", !summary.isEmpty else { return }

            // Update the archived session with the health summary
            if let idx = recentSessions.firstIndex(where: { $0.id == session.id }) {
                recentSessions[idx].healthSummary = summary
                saveToDisk()
            }
        } catch {
            // Non-critical — memory works without summaries, just less rich
        }
    }

    // Maps HealthKit metric type identifiers to natural language search terms
    private func relevantSearchTerms(for metricType: String) -> [String] {
        switch metricType {
        case "heartRateVariabilitySDNN": return ["hrv", "heart rate variability"]
        case "restingHeartRate":         return ["resting heart rate", "rhr", "heart rate"]
        case "sleepDuration":            return ["sleep", "sleeping", "insomnia", "tired"]
        case "sleepEfficiency":          return ["sleep quality", "sleep efficiency", "restless"]
        case "stepCount":                return ["steps", "walking", "activity"]
        case "activeEnergyBurned":       return ["energy", "calories", "workout", "exercise"]
        case "respiratoryRate":          return ["breathing", "respiratory", "breath"]
        case "oxygenSaturation":         return ["oxygen", "spo2", "saturation"]
        default:                         return [metricType.lowercased()]
        }
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
