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

        let finalContext = enrichContextWithMemory(context ?? HealthContextBuilder.buildCurrentContext())

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

            let response = try await api.sendChatMessage(trimmed, history: Array(history), context: finalContext)

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

        let finalContext = enrichContextWithMemory(context ?? HealthContextBuilder.buildCurrentContext())

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
                context: finalContext,
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

        await extractAndStoreConversationMemory(from: session)
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

    // MARK: - Conversation Memory Extraction

    private func extractAndStoreConversationMemory(from session: ChatSession) async {
        guard shouldExtractMemory(from: session) else { return }

        let messages = session.messages
        var conversationText = messages.map { message in
            let roleLabel = message.role == .user ? "User" : "Assistant"
            return "\(roleLabel): \(message.content)"
        }.joined(separator: "\n\n")

        // Hard cap transcript length for memory extraction to avoid oversized requests.
        let maxChars = 8000
        if conversationText.count > maxChars {
            conversationText = String(conversationText.suffix(maxChars))
        }

        let factPrompt = """
        You are a health assistant memory system. Analyze the conversation and extract important facts about the user that should be remembered for future conversations.

        Extract facts in these categories:
        - goal: Health goals the user has mentioned (e.g., "lose 10 pounds", "run a marathon")
        - concern: Health concerns or worries (e.g., "worried about blood pressure", "experiencing fatigue")
        - condition: Medical conditions or diagnoses mentioned (e.g., "has type 2 diabetes", "takes blood pressure medication")
        - preference: User preferences for health advice (e.g., "prefers natural remedies", "vegetarian diet")
        - medication: Medications or supplements the user is taking (e.g., "on 12.5mg enclomiphene", "takes magnesium at night")

        Rules:
        - Only extract facts explicitly stated or strongly implied by the user
        - Do not infer or assume facts not in the conversation
        - Focus on health-relevant information
        - Skip generic greetings or small talk
        - Each fact should be self-contained and understandable without the conversation

        Return a JSON object with this structure:
        {
          "facts": [
            {
              "category": "goal|concern|condition|preference|medication",
              "value": "the fact statement",
              "context": "brief context about when/why this was mentioned"
            }
          ]
        }

        Conversation:
        \(conversationText)
        """

        let summaryPrompt = """
        You are a health assistant memory system. Create a brief summary of this conversation for future reference.

        The summary should:
        - Capture the main topics discussed
        - Note any decisions or action items
        - Highlight key health insights shared
        - Be concise (1–3 sentences)
        - Focus on what would be useful context for future conversations

        Return JSON with this structure:
        {
          "summary": "Brief summary of the conversation",
          "topics": ["topic1", "topic2"],
          "importance": "critical|high|medium|low"
        }

        Conversation:
        \(conversationText)
        """

        do {
            async let factsResponse = api.sendChatMessage(factPrompt, history: [])
            async let summaryResponse = api.sendChatMessage(summaryPrompt, history: [])

            let (factsResult, summaryResult) = try await (factsResponse, summaryResponse)

            let facts = parseFacts(from: factsResult.content)
            let summary = parseSessionSummary(
                from: summaryResult.content,
                messageCount: session.messages.count
            )

            guard let sessionSummary = summary else { return }

            ConversationMemoryStore.shared.upsert(facts: facts, summary: sessionSummary)
        } catch {
            // Non-critical — chat still works without long-term memory
        }
    }

    private func shouldExtractMemory(from session: ChatSession) -> Bool {
        let userMessages = session.messages.filter { $0.role == .user }
        guard userMessages.count >= 2 else { return false }

        let totalLength = userMessages.reduce(0) { $0 + $1.content.count }
        guard totalLength >= 100 else { return false }

        let joined = userMessages.map { $0.content.lowercased() }.joined(separator: " ")
        let healthKeywords = [
            "sleep", "hrv", "heart", "blood pressure", "cholesterol",
            "glucose", "diabetes", "zone 2", "workout", "steps",
            "medication", "supplement", "fatigue", "anxiety", "stress"
        ]
        return healthKeywords.contains { joined.contains($0) }
    }

    private func parseFacts(from response: String) -> [CriticalFact] {
        guard let jsonData = extractFirstJSONObject(from: response) else { return [] }
        struct RawFact: Decodable {
            let category: String
            let value: String
            let context: String?
        }
        struct Payload: Decodable {
            let facts: [RawFact]?
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: jsonData)
            let rawFacts = payload.facts ?? []
            let now = Date()
            return rawFacts.compactMap { raw in
                guard let category = FactCategory(rawValue: raw.category) else { return nil }
                return CriticalFact(
                    id: UUID(),
                    category: category,
                    value: raw.value,
                    context: raw.context,
                    dateIdentified: now,
                    isActive: true
                )
            }
        } catch {
            return []
        }
    }

    private func parseSessionSummary(from response: String, messageCount: Int) -> SessionSummary? {
        guard let jsonData = extractFirstJSONObject(from: response) else { return nil }
        struct RawSummary: Decodable {
            let summary: String
            let topics: [String]?
            let importance: String?
        }

        do {
            let raw = try JSONDecoder().decode(RawSummary.self, from: jsonData)
            let trimmed = raw.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let importance = MemoryImportance(rawValue: raw.importance ?? "medium") ?? .medium

            return SessionSummary(
                id: UUID(),
                date: Date(),
                summary: trimmed,
                topics: raw.topics ?? [],
                importance: importance,
                messageCount: messageCount
            )
        } catch {
            return nil
        }
    }

    private func extractFirstJSONObject(from response: String) -> Data? {
        guard let startIndex = response.firstIndex(of: "{"),
              let endIndex = response.lastIndex(of: "}") else {
            return nil
        }
        let jsonSubstring = response[startIndex...endIndex]
        return jsonSubstring.data(using: .utf8)
    }

    private func enrichContextWithMemory(_ base: AIChatContext?) -> AIChatContext? {
        let memoryCapsule = ConversationMemoryStore.shared.buildMemoryCapsule()

        switch (base, memoryCapsule) {
        case (nil, nil):
            return nil
        case (nil, let memory?):
            return AIChatContext(memory: memory)
        case (let existing?, nil):
            return existing
        case (let existing?, let memory?):
            if existing.memory != nil { return existing }
            return AIChatContext(
                metrics: existing.metrics,
                dateRange: existing.dateRange,
                proactive: existing.proactive,
                memory: memory
            )
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
