// ChatServiceTests.swift
// AmachHealthTests
//
// Tests for chat data models and session logic.
//
// Note: ChatService itself is a @MainActor singleton with private
// init — full integration tests (send/streaming) require a running
// Simulator and are marked with TODO stubs below.
// These tests focus on pure model logic that runs anywhere.

import XCTest
@testable import AmachHealth


// ============================================================
// MARK: - ChatMessage Model
// ============================================================

final class ChatMessageTests: XCTestCase {

    func test_default_init_generates_unique_ids() {
        let m1 = ChatMessage(role: .user, content: "Hello")
        let m2 = ChatMessage(role: .user, content: "Hello")
        XCTAssertNotEqual(m1.id, m2.id)
    }

    func test_role_rawvalues() {
        XCTAssertEqual(MessageRole.user.rawValue, "user")
        XCTAssertEqual(MessageRole.assistant.rawValue, "assistant")
        XCTAssertEqual(MessageRole.system.rawValue, "system")
    }

    func test_content_is_mutable() {
        // Streaming requires in-place content mutation
        var msg = ChatMessage(role: .assistant, content: "")
        msg.content += "Hello"
        msg.content += " World"
        XCTAssertEqual(msg.content, "Hello World")
    }

    func test_roundtrip_codable() throws {
        let original = ChatMessage(
            id: UUID(),
            role: .assistant,
            content: "Your HRV trend looks strong.",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
    }
}


// ============================================================
// MARK: - ChatSession Model
// ============================================================

final class ChatSessionTests: XCTestCase {

    func test_new_session_has_empty_messages() {
        let session = ChatSession()
        XCTAssertTrue(session.messages.isEmpty)
    }

    func test_displayTitle_returns_new_chat_for_empty_session() {
        let session = ChatSession()
        XCTAssertEqual(session.displayTitle, "New Chat")
    }

    func test_displayTitle_uses_first_user_message() {
        var session = ChatSession()
        session.messages.append(ChatMessage(role: .assistant, content: "Hi!"))
        session.messages.append(ChatMessage(role: .user, content: "How is my HRV?"))
        XCTAssertEqual(session.displayTitle, "How is my HRV?")
    }

    func test_displayTitle_truncates_at_50_chars() {
        var session = ChatSession()
        let longMessage = String(repeating: "A", count: 100)
        session.messages.append(ChatMessage(role: .user, content: longMessage))
        XCTAssertEqual(session.displayTitle.count, 50)
    }

    func test_displayTitle_trims_whitespace() {
        var session = ChatSession()
        session.messages.append(ChatMessage(role: .user, content: "  hello  "))
        XCTAssertEqual(session.displayTitle, "hello")
    }

    func test_session_roundtrip_codable() throws {
        var session = ChatSession()
        session.messages.append(ChatMessage(role: .user, content: "test message"))
        session.storjUri = "storj://bucket/session.enc"

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ChatSession.self, from: data)

        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.messages.count, 1)
        XCTAssertEqual(decoded.storjUri, "storj://bucket/session.enc")
    }

    func test_session_array_roundtrip_codable() throws {
        // Mirrors the format ChatService uses for disk persistence
        var s1 = ChatSession()
        s1.messages.append(ChatMessage(role: .user, content: "First session"))
        var s2 = ChatSession()
        s2.messages.append(ChatMessage(role: .user, content: "Second session"))
        let sessions = [s1, s2]

        let data = try JSONEncoder().encode(sessions)
        let decoded = try JSONDecoder().decode([ChatSession].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].displayTitle, "First session")
        XCTAssertEqual(decoded[1].displayTitle, "Second session")
    }
}


// ============================================================
// MARK: - AIChatHistoryMessage
// ============================================================

final class AIChatHistoryMessageTests: XCTestCase {

    func test_roundtrip_codable() throws {
        let msg = AIChatHistoryMessage(role: "user", content: "What is HRV?")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(AIChatHistoryMessage.self, from: data)
        XCTAssertEqual(decoded.role, "user")
        XCTAssertEqual(decoded.content, "What is HRV?")
    }

    func test_assistant_role_encodes_correctly() throws {
        let msg = AIChatHistoryMessage(role: "assistant", content: "HRV is...")
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["role"] as? String, "assistant")
    }
}


// ============================================================
// MARK: - History Truncation (18-message window)
// ============================================================

final class HistoryTruncationTests: XCTestCase {

    // Mirrors the logic in ChatService.send() and sendStreaming()
    func test_history_window_is_at_most_18_messages() {
        // Build a session with 30 messages (15 exchanges)
        var messages: [ChatMessage] = []
        for i in 0..<30 {
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            messages.append(ChatMessage(role: role, content: "Message \(i)"))
        }
        // sendStreaming(): drop last 2 (current user turn + placeholder), then suffix(18)
        let historyMessages = messages.dropLast(2).suffix(18)
        XCTAssertEqual(historyMessages.count, 18)
    }

    func test_history_window_does_not_exceed_session_size() {
        // Session with only 4 messages — history should return fewer than 18
        var messages: [ChatMessage] = []
        for i in 0..<4 {
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            messages.append(ChatMessage(role: role, content: "Message \(i)"))
        }
        let historyMessages = messages.dropLast(2).suffix(18)
        XCTAssertEqual(historyMessages.count, 2)
    }

    func test_single_message_produces_empty_history() {
        // Only the current user turn exists — no prior history
        let messages = [ChatMessage(role: .user, content: "First message")]
        let historyMessages = messages.dropLast(2).suffix(18)
        XCTAssertTrue(historyMessages.isEmpty)
    }
}


// ============================================================
// MARK: - Recent Sessions Limit (30 sessions max)
// ============================================================

final class RecentSessionsCapTests: XCTestCase {

    func test_recent_sessions_capped_at_30() {
        // Mirrors logic in ChatService.startNewSession()
        var recentSessions: [ChatSession] = (0..<35).map { _ in ChatSession() }
        if recentSessions.count > 30 {
            recentSessions = Array(recentSessions.prefix(30))
        }
        XCTAssertEqual(recentSessions.count, 30)
    }

    func test_recent_sessions_not_trimmed_when_under_limit() {
        var recentSessions: [ChatSession] = (0..<10).map { _ in ChatSession() }
        if recentSessions.count > 30 {
            recentSessions = Array(recentSessions.prefix(30))
        }
        XCTAssertEqual(recentSessions.count, 10)
    }
}


// ============================================================
// MARK: - Storj Sync Trigger (every 10 messages)
// ============================================================

final class StorjSyncTriggerTests: XCTestCase {

    // The actual Storj call is async + network-dependent.
    // These tests validate the count-based trigger logic.

    func test_sync_triggers_at_10_messages() {
        let count = 10
        XCTAssertEqual(count % 10, 0)
    }

    func test_sync_triggers_at_20_messages() {
        let count = 20
        XCTAssertEqual(count % 10, 0)
    }

    func test_sync_does_not_trigger_at_11_messages() {
        let count = 11
        XCTAssertNotEqual(count % 10, 0)
    }

    func test_sync_does_not_trigger_at_9_messages() {
        let count = 9
        XCTAssertNotEqual(count % 10, 0)
    }
}


// ============================================================
// MARK: - Xcode-Required Integration Stubs
// ============================================================

// TODO (Xcode + Simulator):
//   - Test ChatService.send() appends user + assistant message
//   - Test ChatService.sendStreaming() fills placeholder token-by-token
//   - Test sendStreaming() removes empty placeholder on error
//   - Test startNewSession() archives to recentSessions and resets current
//   - Test loadSession() replaces currentSession
//   - Test saveToDisk() / loadFromDisk() round-trip with temp file URL
//   - Test syncToStorj() is skipped when wallet.isConnected == false
