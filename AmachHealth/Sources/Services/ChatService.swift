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
    /// Quick vs deep mode for Luma. Toggle in ChatView; resets on new session.
    @Published var chatMode: ChatMode = .quick

    /// Tracks the in-flight send task so the user can cancel it.
    private var sendingTask: Task<Void, Never>?

    /// The text of the last message that failed, available for retry.
    @Published var lastFailedMessage: String?

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

    // MARK: - Cancel

    /// Cancels the in-flight Luma request. Safe to call from any context.
    func cancelCurrentRequest() {
        sendingTask?.cancel()
        sendingTask = nil
        isSending = false
        // Remove the empty assistant placeholder if nothing was written yet
        if let last = currentSession.messages.last,
           last.role == .assistant,
           last.content.isEmpty {
            currentSession.messages.removeLast()
        }
        error = nil   // cancel is intentional — no error banner
    }

    /// Re-sends the last failed message. Removes it from history first so it
    /// isn't duplicated, then calls startStreaming as normal.
    func retryLastMessage() {
        guard let text = lastFailedMessage else { return }
        // Remove the dangling user message left by the failed attempt
        if let last = currentSession.messages.last, last.role == .user, last.content == text {
            currentSession.messages.removeLast()
        }
        lastFailedMessage = nil
        error = nil
        startStreaming(text)
    }

    // MARK: - Send Message

    // MARK: - send() — non-streaming (request/response via /api/ai/chat)
    //
    // Retained for fallback and contexts where streaming isn't needed.
    // For progressive token delivery, use sendStreaming() instead.

    func send(_ text: String, context: AIChatContext? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let intent = ChatIntentClassifier.classify(trimmed)
        // Labs are expensive even with caching. Only include lab data for
        // explicit lab/body-composition intents, or when in deep mode.
        let needsLabs = chatMode == .deep || intent == .labs || intent == .bodyComp
        let labDataToUse: LabDataContext? = needsLabs ? await HealthContextBuilder.buildLabContext() : nil
        // Build context blocks after lab context is warmed so Luma always
        // gets labs_bloodwork / labs_dexa in `contextBlocks` for this turn.
        let baseContext = context ?? HealthContextBuilder.buildContext(for: intent, mode: chatMode)
        let finalContext = enrichContext(baseContext, labData: labDataToUse, intent: intent, mode: chatMode)

        let userMsg = ChatMessage(role: .user, content: trimmed)
        currentSession.messages.append(userMsg)
        currentSession.updatedAt = .now
        saveToDisk()

        isSending = true
        error = nil

        do {
            let limit = historyLimit(for: finalContext, hasLabData: labDataToUse != nil)
            let historyForSend = currentSession.messages
                .dropLast()
                .suffix(limit)
                .map { AIChatHistoryMessage(role: $0.role.rawValue, content: $0.content) }

            let response = try await api.sendChatMessage(trimmed, history: Array(historyForSend), context: finalContext, mode: chatMode)

            let assistantMsg = ChatMessage(role: .assistant, content: response.content)
            currentSession.messages.append(assistantMsg)
            currentSession.updatedAt = .now
            saveToDisk()

            updateRollingSummaryIfNeeded()
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

    /// Wraps sendStreaming in a cancellable Task and stores it for later cancellation.
    func startStreaming(_ text: String, context: AIChatContext? = nil) {
        sendingTask?.cancel()
        sendingTask = Task {
            await sendStreaming(text, context: context)
        }
    }

    func sendStreaming(_ text: String, context: AIChatContext? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let intent = ChatIntentClassifier.classify(trimmed)
        // Labs are expensive even with caching. Only include lab data for
        // explicit lab/body-composition intents, or when in deep mode.
        let needsLabs = chatMode == .deep || intent == .labs || intent == .bodyComp
        
        // 1. Append user message + assistant placeholder immediately so the UI
        // renders without waiting on any network/decryption work.
        currentSession.messages.append(ChatMessage(role: .user, content: trimmed))
        currentSession.updatedAt = .now

        // 2. Append empty assistant placeholder — tokens fill it in
        currentSession.messages.append(ChatMessage(role: .assistant, content: ""))
        let assistantIdx = currentSession.messages.count - 1

        isSending = true
        error = nil

        // Warm lab context (if needed) before building context blocks.
        let labDataToUse: LabDataContext? = needsLabs ? await HealthContextBuilder.buildLabContext() : nil
        // If user cancelled while we were loading lab context, bail out cleanly.
        guard !Task.isCancelled else {
            if currentSession.messages.indices.contains(assistantIdx),
               currentSession.messages[assistantIdx].content.isEmpty {
                currentSession.messages.remove(at: assistantIdx)
            }
            isSending = false
            sendingTask = nil
            return
        }

        let baseContext = context ?? HealthContextBuilder.buildContext(for: intent, mode: chatMode)
        let finalContext = enrichContext(baseContext, labData: labDataToUse, intent: intent, mode: chatMode)

        let dynamicLimit = historyLimit(for: finalContext, hasLabData: labDataToUse != nil)
        let historyMessages = currentSession.messages
            .dropLast(2)
            .suffix(dynamicLimit)
            .map { AIChatHistoryMessage(role: $0.role.rawValue, content: $0.content) }

        #if DEBUG
        let blockTypes = finalContext?.contextBlocks?.map { $0.type }.joined(separator: ", ") ?? "nil"
        let bwCount = labDataToUse?.bloodwork?.count ?? 0
        let dxCount = labDataToUse?.dexa?.count ?? 0
        let recentCount = labDataToUse?.recentEvents?.count ?? 0
        let hasMem = finalContext?.memory != nil
        let memGoals = finalContext?.memory?.activeGoals.count ?? 0
        let memNotes = finalContext?.memory?.recentSessionNotes.count ?? 0
        print("""
        🧩 [Luma] intent=\(intent) mode=\(chatMode) includesLabData=\(intent.includesLabData)
        🧩 [Luma] contextBlocks=\(blockTypes)
        🧩 [Luma] labData=bw:\(bwCount) dexa:\(dxCount) recentEvents:\(recentCount)
        🧩 [Luma] memory=\(hasMem) goals:\(memGoals) notes:\(memNotes)
        🧩 [Luma] history=\(historyMessages.count) msgs, rollingSummary=\(currentSession.rollingSummary != nil)
        """)
        #endif

        let screen = LumaContextService.shared.currentScreen
        let metric = LumaContextService.shared.currentMetric

        var didRetryAfterTimeout = false
        var didRetryAfterEmptyContent = false

        do {
            let stream = api.streamLumaChat(
                trimmed,
                history: historyMessages,
                context: finalContext,
                screen: screen,
                metric: metric,
                mode: chatMode
            )

            for try await token in stream {
                currentSession.messages[assistantIdx].content += token
                currentSession.updatedAt = .now
            }

            lastFailedMessage = nil
            saveToDisk()
            AmachHaptics.lumaResponse()

            updateRollingSummaryIfNeeded()
        } catch {
            let isEmptyResponse = (error.localizedDescription + " " + String(describing: error))
                .contains("Luma returned an empty response")

            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                // Cancelled — clean up silently
                if currentSession.messages.indices.contains(assistantIdx),
                   currentSession.messages[assistantIdx].content.isEmpty {
                    currentSession.messages.remove(at: assistantIdx)
                }
                if let idx = currentSession.messages.lastIndex(where: { $0.role == .user && $0.content == trimmed }) {
                    currentSession.messages.remove(at: idx)
                }
                saveToDisk()
                self.error = nil
            } else if isEmptyResponse, !didRetryAfterEmptyContent {
                didRetryAfterEmptyContent = true

                #if DEBUG
                print("⚠️ Luma returned empty content; retrying once.")
                #endif

                // Reset assistant placeholder for retry
                if currentSession.messages.indices.contains(assistantIdx),
                   currentSession.messages[assistantIdx].role == .assistant {
                    currentSession.messages[assistantIdx].content = ""
                } else {
                    currentSession.messages.append(ChatMessage(role: .assistant, content: ""))
                }
                let retryIdx = currentSession.messages.lastIndex(where: { $0.role == .assistant }) ?? assistantIdx

                do {
                    let stream = api.streamLumaChat(
                        trimmed,
                        history: historyMessages,
                        context: finalContext,
                        screen: screen,
                        metric: metric,
                        mode: chatMode
                    )
                    for try await token in stream {
                        currentSession.messages[retryIdx].content += token
                        currentSession.updatedAt = .now
                    }
                    lastFailedMessage = nil
                    saveToDisk()
                    updateRollingSummaryIfNeeded()
                    isSending = false
                    sendingTask = nil
                    return
                } catch {
                    // Retry also failed — fall through to fallback below
                }

                // Both attempts returned empty: show a helpful fallback
                // instead of a blank bubble or removing the turn entirely.
                let fallback = "I don't have enough context to answer that right now. " +
                    "Could you give me a bit more detail?"
                if currentSession.messages.indices.contains(retryIdx) {
                    currentSession.messages[retryIdx].content = fallback
                }
                lastFailedMessage = nil
                saveToDisk()
            } else {
                // Timeout or other error — show fallback instead of removing
                if currentSession.messages.indices.contains(assistantIdx),
                   currentSession.messages[assistantIdx].content.isEmpty {
                    let fallback = (error as? URLError)?.code == .timedOut
                        ? "Sorry, I took too long to respond. Could you try asking again?"
                        : "Something went wrong on my end. Please try again."
                    currentSession.messages[assistantIdx].content = fallback
                }
                saveToDisk()
                self.lastFailedMessage = trimmed
            }
        }

        isSending = false
        sendingTask = nil
    }

    // MARK: - Session Management

    func startNewSession() {
        guard !currentSession.messages.isEmpty else { return }

        chatMode = .quick
        lastFailedMessage = nil
        error = nil
        let sessionToArchive = currentSession

        // Archive current to recent sessions — keep only the last 3 visible.
        // Older sessions have already had their facts extracted into
        // ConversationMemoryStore when they were archived.
        recentSessions.insert(sessionToArchive, at: 0)
        if recentSessions.count > 3 {
            recentSessions = Array(recentSessions.prefix(3))
        }
        saveToDisk()

        // Summarize health content, extract memory, and sync to Storj.
        // Use Task.detached so this survives view dismissal / session reset.
        Task.detached { [weak self] in
            await self?.summarizeAndArchive(sessionToArchive)
            await self?.syncSessionToStorj(sessionToArchive)
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
        let veniceContext = enrichContext(
            AIChatContext(proactive: service.buildVeniceContext(for: event))
        )

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

    // MARK: - Feedback

    /// Rate a Luma response. Captures the anonymized exchange and sends it to
    /// the backend for quality monitoring — no health metric values are included,
    /// only the raw text of the user prompt and Luma's reply.
    func submitFeedback(_ feedback: MessageFeedback, for messageId: UUID, comment: String? = nil) {
        guard let idx = currentSession.messages.firstIndex(where: { $0.id == messageId }),
              currentSession.messages[idx].role == .assistant else { return }

        currentSession.messages[idx].feedback = feedback
        saveToDisk()

        let screen = LumaContextService.shared.currentScreen

        Task {
            try? await api.submitChatFeedback(rating: feedback.rawValue, screen: screen, comment: comment)
        }
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
        guard session.messages.count >= 2 else { return }  // need at least one exchange
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

            await ConversationMemoryStore.shared.syncToStorj()
        } catch {
            // Non-critical — chat still works without long-term memory
        }
    }

    private func shouldExtractMemory(from session: ChatSession) -> Bool {
        let userMessages = session.messages.filter { $0.role == .user }
        guard !userMessages.isEmpty else { return false }

        // Any substantive user input is worth extracting — the LLM decides
        // what's actually memory-worthy.  Only skip very short throwaway
        // sessions (single "hi"/"thanks" with no real content).
        let totalLength = userMessages.reduce(0) { $0 + $1.content.count }
        return totalLength >= 20
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

    // MARK: - Rolling Summary (Progressive Summarization)

    /// Summarize older messages so the history window stays compact.
    /// Triggered after long conversations — the summary rides along as a context block.
    private func updateRollingSummaryIfNeeded() {
        let messageCount = currentSession.messages.count
        guard messageCount >= 20 else { return }
        guard currentSession.rollingSummary == nil || messageCount % 10 == 0 else { return }

        Task {
            let messagesToSummarize = Array(currentSession.messages.dropLast(8))
            var text = messagesToSummarize.map { msg in
                let role = msg.role == .user ? "User" : "Assistant"
                return "\(role): \(msg.content)"
            }.joined(separator: "\n\n")

            let maxChars = 6000
            if text.count > maxChars {
                text = String(text.suffix(maxChars))
            }

            let prompt = """
            Summarize this earlier part of a health conversation in 3-5 sentences. \
            Preserve: specific numbers/metrics discussed, decisions made, questions answered, \
            and any action items. Skip greetings and small talk.

            Conversation:
            \(text)
            """

            do {
                let response = try await api.sendChatMessage(prompt, history: [])
                let summary = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !summary.isEmpty else { return }
                currentSession.rollingSummary = summary
                saveToDisk()
            } catch {
                // Non-critical — raw messages still work as fallback
            }
        }
    }

    // MARK: - Token Budget

    /// Estimate tokens for the assembled context to dynamically size the history window.
    private func historyLimit(for context: AIChatContext?, hasLabData: Bool) -> Int {
        let contextTokens = Self.estimateContextTokens(context)

        // If a rolling summary covers older messages, we need fewer raw messages
        let hasRollingSummary = currentSession.rollingSummary != nil

        let budget = 8000
        let historyBudget = max(budget - contextTokens, 1000)
        let avgMessageTokens = 60
        var limit = min(max(historyBudget / avgMessageTokens, 6), 18)

        if hasLabData { limit = min(limit, 10) }
        if hasRollingSummary { limit = min(limit, 8) }

        return limit
    }

    private static func estimateContextTokens(_ context: AIChatContext?) -> Int {
        guard let ctx = context else { return 0 }
        var tokens = 0
        if let blocks = ctx.contextBlocks {
            tokens += blocks.reduce(0) { $0 + ($1.content.count + 3) / 4 }
        }
        if let mem = ctx.memory {
            let memText = (mem.activeGoals + mem.activeConcerns + mem.medications
                           + mem.conditions + mem.recentSessionNotes).joined(separator: " ")
            tokens += (memText.count + 3) / 4
        }
        return tokens
    }

    // MARK: - Context Enrichment

    private func enrichContext(
        _ base: AIChatContext?,
        labData: LabDataContext? = nil,
        intent: ChatIntent? = nil,
        mode: ChatMode = .quick
    ) -> AIChatContext? {
        let memoryCapsule = ConversationMemoryStore.shared.buildMemoryCapsule(intent: intent, mode: mode)
        let walletAddress = wallet.isConnected ? wallet.address : nil

        guard base != nil || memoryCapsule != nil || walletAddress != nil else {
            return nil
        }

        let existing = base ?? AIChatContext()

        var blocks = existing.contextBlocks ?? []
        if let rollingSummary = currentSession.rollingSummary {
            blocks.insert(
                ContextBlock(type: "session_context",
                             content: "Earlier in this conversation: \(rollingSummary)"),
                at: 0
            )
        }

        return AIChatContext(
            metrics: existing.metrics,
            dateRange: existing.dateRange,
            proactive: existing.proactive,
            memory: existing.memory ?? memoryCapsule,
            userAddress: existing.userAddress ?? walletAddress,
            labData: existing.labData ?? labData,
            contextBlocks: blocks.isEmpty ? nil : blocks
        )
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

        // First entry is the active session, rest are history (cap at 3)
        currentSession = sessions[0]
        recentSessions = Array(sessions.dropFirst().prefix(3))
    }

    // MARK: - Storj Sync
    //
    // Raw session sync is now archive-only (not every 10 messages).
    // The distilled ConversationMemoryStore syncs after fact extraction,
    // which is the high-value, low-size data that matters cross-platform.

    private func syncSessionToStorj(_ session: ChatSession) async {
        guard !session.messages.isEmpty else { return }
        guard wallet.isConnected, let key = wallet.encryptionKey else { return }

        do {
            let uri = try await api.storeChatSession(
                session,
                walletAddress: key.walletAddress,
                encryptionKey: key
            )
            if session.id == currentSession.id {
                currentSession.storjUri = uri
                saveToDisk()
            }
        } catch {
            #if DEBUG
            print("⚠️ ChatService: Storj session sync failed: \(error.localizedDescription)")
            #endif
        }
    }
}
