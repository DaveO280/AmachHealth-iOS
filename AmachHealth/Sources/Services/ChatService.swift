// ChatService.swift
// AmachHealth
//
// Manages Luma AI chat sessions:
// - Real-time message state
// - Local persistence in the vault (chat_sessions / chat_messages)
// - Storj save of each archived session while VaultFlags.legacyStorjWrites is on

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

    // Allow protocol types so tests can inject mocks.
    // Production code always uses the shared singletons via private init().
    private let api: any AmachAPIClientProtocol
    private let wallet: any WalletServiceProtocol

    /// Sessions shown in the history list. The vault keeps every session.
    static let visibleRecentSessions = 30

    /// Where sessions persist. Production reads LocalVault; tests inject one.
    private let vaultProvider: () -> VaultDatabase?
    private var vault: VaultDatabase? { vaultProvider() }

    private init() {
        self.api = AmachAPIClient.shared
        self.wallet = WalletService.shared
        self.vaultProvider = { LocalVault.shared.database }
        // Sessions load when the vault opens (vaultDidChange).
    }

    // MARK: - Test-only initializer (DEBUG builds only)
    // Injects mock dependencies; never called from production code.
    #if DEBUG
    init(
        injectedAPI: any AmachAPIClientProtocol,
        injectedWallet: any WalletServiceProtocol,
        injectedVault: VaultDatabase? = nil
    ) {
        self.api = injectedAPI
        self.wallet = injectedWallet
        self.vaultProvider = { injectedVault }
        loadFromVault()
    }
    #endif

    /// Called by LocalVault when the vault opens or closes.
    func vaultDidChange() {
        if vault == nil {
            currentSession = ChatSession()
            recentSessions = []
        } else {
            loadFromVault()
        }
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
        // Drop Luma's "enclave busy" / "out of credit" note so the retry replaces it
        if let last = currentSession.messages.last, last.role == .assistant,
           Self.isPauseReply(last.content) {
            currentSession.messages.removeLast()
        }
        // Remove the dangling user message left by the failed attempt
        if let last = currentSession.messages.last, last.role == .user, last.content == text {
            currentSession.messages.removeLast()
        }
        lastFailedMessage = nil
        error = nil
        startStreaming(text)
    }

    // MARK: - Feedback availability

    /// Luma response rating is hidden: /api/feedback exists on no backend
    /// branch, and feedback text would leave the private path. Re-enable once
    /// a private feedback route exists.
    static let feedbackEnabled = false

    // MARK: - Enclave busy

    /// Luma's reply when every private (enclave) model is at capacity.
    /// The server never falls back to a non-private model, so this is a
    /// pause, not an error.
    static let enclaveBusyReply =
        "I think things through in a private enclave so your data stays sealed, " +
        "and it's full for the moment. Give it a minute and tap Try Again. " +
        "Your question is saved."

    private static let creditReplyPrefix = "My private AI has used up today's credit"

    /// Luma's reply when the AI account's daily credit is spent.
    static func creditExhaustedReply(resetsAt: Date?) -> String {
        let refresh = APIError.creditExhaustedMessage(resetsAt: resetsAt)
            .components(separatedBy: "It refreshes").last.map { "It refreshes" + $0 } ?? ""
        return "\(creditReplyPrefix), so I can't think this through right now. \(refresh) " +
            "Your question is saved: tap Try Again then."
    }

    /// Luma's reply for a pause that isn't a failure (enclave full, daily
    /// credit spent), or nil for a real error.
    static func pauseReply(for error: Error) -> String? {
        switch error as? APIError {
        case .enclaveBusy: return enclaveBusyReply
        case .aiCreditExhausted(let resetsAt): return creditExhaustedReply(resetsAt: resetsAt)
        default: return nil
        }
    }

    static func isPauseReply(_ content: String) -> Bool {
        content == enclaveBusyReply || content.hasPrefix(creditReplyPrefix)
    }

    // MARK: - Send Message

    // MARK: - send() — non-streaming (request/response via /api/ai/chat)
    //
    // Retained for fallback and contexts where streaming isn't needed.
    // For progressive token delivery, use sendStreaming() instead.

    func send(_ text: String, context: AIChatContext? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let intents = ChatIntentClassifier.classifyAll(trimmed)
        let intent = intents[0]
        // Labs are expensive even with caching. Only include lab data for
        // explicit lab/body-composition intents, or when in deep mode.
        let needsLabs = chatMode == .deep || intents.contains(.labs) || intents.contains(.bodyComp)
        let labDataToUse: LabDataContext? = needsLabs ? await HealthContextBuilder.buildLabContext() : nil
        // Metrics as of now, not whenever the dashboard last loaded (5-minute cache).
        if context == nil { await DashboardService.shared.load() }
        // Build context blocks after lab context is warmed so Luma always
        // gets labs_bloodwork / labs_dexa in `contextBlocks` for this turn.
        let baseContext = context ?? HealthContextBuilder.buildContext(
            for: intent, mode: chatMode, message: trimmed, intents: Set(intents))
        let finalContext = enrichContext(baseContext, labData: labDataToUse, intent: intent, mode: chatMode)
        LumaContextInspector.shared.record(finalContext, intent: intent, mode: chatMode)

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
            extractMemoryIfDue()
        } catch where Self.pauseReply(for: error) != nil {
            currentSession.messages.append(ChatMessage(role: .assistant, content: Self.pauseReply(for: error)!))
            currentSession.updatedAt = .now
            saveToDisk()
            self.error = nil
            self.lastFailedMessage = trimmed
        } catch {
            self.error = error.localizedDescription
            self.lastFailedMessage = trimmed
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

        let intents = ChatIntentClassifier.classifyAll(trimmed)
        let intent = intents[0]
        // Labs are expensive even with caching. Only include lab data for
        // explicit lab/body-composition intents, or when in deep mode.
        let needsLabs = chatMode == .deep || intents.contains(.labs) || intents.contains(.bodyComp)
        
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
        // Metrics as of now, not whenever the dashboard last loaded (5-minute cache).
        if context == nil { await DashboardService.shared.load() }
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

        let baseContext = context ?? HealthContextBuilder.buildContext(
            for: intent, mode: chatMode, message: trimmed, intents: Set(intents))
        let finalContext = enrichContext(baseContext, labData: labDataToUse, intent: intent, mode: chatMode)
        LumaContextInspector.shared.record(finalContext, intent: intent, mode: chatMode)

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
            extractMemoryIfDue()
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
                    extractMemoryIfDue()
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
            } else if let reply = Self.pauseReply(for: error) {
                if currentSession.messages.indices.contains(assistantIdx),
                   currentSession.messages[assistantIdx].role == .assistant {
                    currentSession.messages[assistantIdx].content = reply
                } else {
                    currentSession.messages.append(ChatMessage(role: .assistant, content: reply))
                }
                saveToDisk()
                self.error = nil
                self.lastFailedMessage = trimmed
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

        // Archive current to recent sessions. The vault keeps every session;
        // the list shows the most recent ones.
        recentSessions.insert(sessionToArchive, at: 0)
        if recentSessions.count > Self.visibleRecentSessions {
            recentSessions = Array(recentSessions.prefix(Self.visibleRecentSessions))
        }
        currentSession = ChatSession()
        saveToDisk()

        // Summarize health content and extract memory. The vault keeps the
        // session; encrypted backup (if on) carries it off the phone.
        // Use Task.detached so this survives view dismissal / session reset.
        Task.detached { [weak self] in
            await self?.summarizeAndArchive(sessionToArchive)
        }
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
        } catch where Self.pauseReply(for: error) != nil {
            currentSession.messages[idx].content = Self.pauseReply(for: error)!
            saveToDisk()
            self.error = nil
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
        guard Self.feedbackEnabled else { return }
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
        if session.healthSummary == nil { await summarizeHealth(session) }
        // A reopened session may have new messages even if already summarized.
        await extractSessionMemory(from: session)
    }

    private func summarizeHealth(_ session: ChatSession) async {
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

    // MARK: - Conversation Memory Extraction

    /// Read the open session for memory once it has this many user messages
    /// not yet read, so memory builds without the user tapping New Chat.
    static let memoryExtractionInterval = 10

    /// The latest background extraction, so tests can wait for it.
    private(set) var memoryExtractionTask: Task<Void, Never>?
    private var sessionsBeingExtracted: Set<UUID> = []

    private func extractMemoryIfDue() {
        let session = currentSession
        let read = ConversationMemoryStore.shared.extractedMessageCount(sessionId: session.id)
        let unread = session.messages.dropFirst(read).filter { $0.role == .user }.count
        guard unread >= Self.memoryExtractionInterval else { return }
        memoryExtractionTask = Task { await extractSessionMemory(from: session) }
    }

    /// Read the open session for memory now (app going to the background,
    /// chat closed). Does nothing if nothing substantial is new.
    func extractCurrentSessionMemory() async {
        await extractSessionMemory(from: currentSession)
    }

    /// Extract facts from the messages not yet read, retire facts they say no
    /// longer hold, and update this session's one summary.
    func extractSessionMemory(from session: ChatSession) async {
        let memory = ConversationMemoryStore.shared
        let read = min(memory.extractedMessageCount(sessionId: session.id), session.messages.count)
        let newMessages = Array(session.messages.dropFirst(read))
        guard shouldExtractMemory(from: newMessages),
              !sessionsBeingExtracted.contains(session.id) else { return }
        sessionsBeingExtracted.insert(session.id)
        defer { sessionsBeingExtracted.remove(session.id) }

        var conversationText = newMessages.map { message -> String in
            let roleLabel = message.role == .user ? "User" : "Assistant"
            return "\(roleLabel): \(message.content)"
        }.joined(separator: "\n\n")

        // Hard cap transcript length for memory extraction to avoid oversized requests.
        let maxChars = 8000
        if conversationText.count > maxChars {
            conversationText = String(conversationText.suffix(maxChars))
        }

        // Facts already remembered, by reference, so the extractor can retire them.
        let known = memory.activeFactsForReview()
        let knownRefs = Dictionary(uniqueKeysWithValues: known.enumerated().map { ("F\($0.offset + 1)", $0.element) })
        let knownList = known.isEmpty ? "(none)" : known.enumerated()
            .map { "F\($0.offset + 1) [\($0.element.category.rawValue)] \($0.element.value)" }
            .joined(separator: "\n")

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
        - Do not repeat a fact already remembered (listed below) unless it changed

        Facts already remembered:
        \(knownList)

        Retire a remembered fact only if the user says it no longer holds: they stopped a medication or supplement, reached or dropped a goal, a concern resolved, a preference changed. A changed dose retires the old fact and adds the new one. List retired facts by their reference (e.g. "F2").

        Return a JSON object with this structure:
        {
          "facts": [
            {
              "category": "goal|concern|condition|preference|medication",
              "value": "the fact statement",
              "context": "brief context about when/why this was mentioned"
            }
          ],
          "retire": ["F2"]
        }

        Conversation:
        \(conversationText)
        """

        let previousSummary = memory.summary(forSession: session.id)
        let summarySoFar = previousSummary.map {
            """

            Summary of this conversation so far:
            \($0.summary)

            Write one summary covering both that and the new messages below.
            """
        } ?? ""

        let summaryPrompt = """
        You are a health assistant memory system. Create a brief summary of this conversation for future reference.

        The summary should:
        - Capture the main topics discussed
        - Note any decisions or action items
        - Highlight key health insights shared
        - Be concise (1–3 sentences)
        - Focus on what would be useful context for future conversations
        \(summarySoFar)
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

            let (facts, retire) = parseFacts(from: factsResult.content)
            let retiredIds = Set(retire.compactMap { ref -> UUID? in
                if let fact = knownRefs[ref.trimmingCharacters(in: .whitespaces).uppercased()] { return fact.id }
                // Some replies name the fact instead of its reference.
                let norm = ConversationMemoryStore.normalizeFactValue(ref)
                return known.first { ConversationMemoryStore.normalizeFactValue($0.value) == norm }?.id
            })
            var summary = parseSessionSummary(from: summaryResult.content, messageCount: session.messages.count)
            if let parsed = summary {
                summary = SessionSummary(id: session.id, date: Date(), summary: parsed.summary, topics: parsed.topics,
                                         importance: parsed.importance, messageCount: parsed.messageCount)
            }

            memory.upsert(facts: facts, summary: summary, retiring: retiredIds)
            memory.markExtracted(sessionId: session.id, messageCount: session.messages.count)
        } catch {
            // Non-critical — chat still works without long-term memory. The
            // messages stay unread and are tried again next time.
        }
    }

    private func shouldExtractMemory(from messages: [ChatMessage]) -> Bool {
        let userMessages = messages.filter { $0.role == .user }
        guard !userMessages.isEmpty else { return false }

        // Any substantive user input is worth extracting — the LLM decides
        // what's actually memory-worthy.  Only skip very short throwaway
        // sessions (single "hi"/"thanks" with no real content).
        let totalLength = userMessages.reduce(0) { $0 + $1.content.count }
        return totalLength >= 20
    }

    private func parseFacts(from response: String) -> (facts: [CriticalFact], retire: [String]) {
        guard let jsonData = extractFirstJSONObject(from: response) else { return ([], []) }
        struct RawFact: Decodable {
            let category: String
            let value: String
            let context: String?
        }
        /// "F2", or an object naming it.
        struct RetireRef: Decodable {
            let ref: String?
            init(from decoder: Decoder) throws {
                if let text = try? decoder.singleValueContainer().decode(String.self) {
                    ref = text
                    return
                }
                struct Keyed: Decodable { let id: String?; let ref: String?; let value: String? }
                let keyed = try Keyed(from: decoder)
                ref = keyed.id ?? keyed.ref ?? keyed.value
            }
        }
        struct Payload: Decodable {
            let facts: [RawFact]?
            let retire: [RetireRef]?
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: jsonData)
            let rawFacts = payload.facts ?? []
            let now = Date()
            let facts = rawFacts.compactMap { raw -> CriticalFact? in
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
            return (facts, (payload.retire ?? []).compactMap(\.ref))
        } catch {
            return ([], [])
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
            var text = messagesToSummarize.map { msg -> String in
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
                           + mem.conditions + mem.preferences + mem.recentSessionNotes).joined(separator: " ")
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
        // The backend reads only contextBlocks, so memory travels as a block too.
        if let memory = existing.memory ?? memoryCapsule, !blocks.contains(where: { $0.type == "memory" }) {
            let draw = LabContextService.shared.currentContext()?.bloodwork?.reportDate
            blocks.append(ContextBlock(type: "memory",
                                       content: HealthContextBuilder.formatMemory(memory, latestBloodwork: draw)))
        }
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
        guard let vault else { return }
        let all = [currentSession] + recentSessions.filter { $0.id != currentSession.id }
        do {
            try vault.saveChatSessions(all.filter { !$0.messages.isEmpty || $0.id == currentSession.id },
                                       currentId: currentSession.id)
        } catch {
            #if DEBUG
            print("⚠️ ChatService: vault write failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func loadFromVault() {
        guard let vault, let stored = try? vault.loadChatSessions(recentLimit: Self.visibleRecentSessions) else { return }
        currentSession = stored.current ?? ChatSession()
        recentSessions = stored.recent.filter { $0.id != currentSession.id }
    }
}

#if DEBUG
extension ChatService {
    /// DEBUG: Replace active + recent sessions from a replay fixture (preserves message timestamps).
    func debugApplyReplaySessions(current: ChatSession, recent: [ChatSession]) {
        currentSession = current
        recentSessions = recent
        saveToDisk()
    }
}
#endif
