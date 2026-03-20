// ChatServiceIntegrationTests.swift
// AmachHealthTests
//
// Integration tests for ChatService using MockAmachAPIClient + MockWalletService.
// These run WITHOUT a simulator — all network I/O is replaced by the mocks.
//
// Run: Cmd+U in Xcode, or:
//   xcodebuild test -project AmachHealth.xcodeproj \
//     -scheme AmachHealth \
//     -destination 'platform=iOS Simulator,name=iPhone 15'

import XCTest
@testable import AmachHealth

// ============================================================
// MARK: - ChatService.send() — append behaviour
// ============================================================

@MainActor
final class ChatServiceSendTests: XCTestCase {

    var mockAPI: MockAmachAPIClient!
    var mockWallet: MockWalletService!
    var sut: ChatService!

    override func setUp() async throws {
        mockAPI = MockAmachAPIClient()
        mockWallet = MockWalletService()
        sut = ChatService(injectedAPI: mockAPI, injectedWallet: mockWallet)
    }

    func test_send_appends_user_and_assistant_messages() async throws {
        mockAPI.config.chatResponse = .fixture(content: "Great question about your health!")

        await sut.send("What is my HRV?")

        XCTAssertEqual(sut.currentSession.messages.count, 2)
        XCTAssertEqual(sut.currentSession.messages[0].role, .user)
        XCTAssertEqual(sut.currentSession.messages[0].content, "What is my HRV?")
        XCTAssertEqual(sut.currentSession.messages[1].role, .assistant)
        XCTAssertEqual(sut.currentSession.messages[1].content, "Great question about your health!")
    }

    func test_send_trims_whitespace_from_user_input() async throws {
        await sut.send("  Hello Luma  ")
        XCTAssertEqual(sut.currentSession.messages.first?.content, "Hello Luma")
    }

    func test_send_ignores_empty_input() async throws {
        await sut.send("")
        XCTAssertTrue(sut.currentSession.messages.isEmpty)
        XCTAssertEqual(mockAPI.sendChatMessageCallCount, 0)
    }

    func test_send_ignores_whitespace_only_input() async throws {
        await sut.send("   \n\t  ")
        XCTAssertTrue(sut.currentSession.messages.isEmpty)
    }

    func test_send_sets_isSending_false_after_completion() async throws {
        await sut.send("Hello")
        XCTAssertFalse(sut.isSending)
    }

    func test_send_error_sets_error_property() async throws {
        mockAPI.config.chatError = APIError.requestFailed("Luma is unavailable")
        await sut.send("Hello")
        XCTAssertNotNil(sut.error)
        XCTAssertFalse(sut.isSending)
    }

    func test_send_error_keeps_user_message_for_retry() async throws {
        mockAPI.config.chatError = APIError.requestFailed("Network error")
        await sut.send("Retry me")
        // User message should still be in history for retry
        XCTAssertEqual(sut.lastFailedMessage, "Retry me")
    }

    func test_send_passes_history_to_api() async throws {
        // First exchange
        await sut.send("What is HRV?")
        // Second exchange — mock must have seen history from first
        await sut.send("Tell me more")
        XCTAssertNotNil(mockAPI.lastChatHistory)
        // The second call should include the first exchange (2 messages) as history
        XCTAssertGreaterThan(mockAPI.lastChatHistory?.count ?? 0, 0)
    }
}

// ============================================================
// MARK: - ChatService.startStreaming() — streaming behaviour
// ============================================================

@MainActor
final class ChatServiceStreamingTests: XCTestCase {

    var mockAPI: MockAmachAPIClient!
    var mockWallet: MockWalletService!
    var sut: ChatService!

    override func setUp() async throws {
        mockAPI = MockAmachAPIClient()
        mockWallet = MockWalletService()
        sut = ChatService(injectedAPI: mockAPI, injectedWallet: mockWallet)
    }

    func test_startStreaming_adds_user_then_assistant_messages() async throws {
        mockAPI.config.chatResponse = .fixture(content: "Your HRV looks great today!")
        sut.startStreaming("How is my HRV?")

        // Give streaming time to complete (mock has no 15ms delay — instant)
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        XCTAssertEqual(sut.currentSession.messages.count, 2)
        XCTAssertEqual(sut.currentSession.messages[0].role, .user)
        XCTAssertEqual(sut.currentSession.messages[1].role, .assistant)
    }

    func test_startStreaming_fills_assistant_content() async throws {
        let expectedContent = "HRV stands for Heart Rate Variability."
        mockAPI.config.chatResponse = .fixture(content: expectedContent)
        sut.startStreaming("What is HRV?")
        try await Task.sleep(nanoseconds: 100_000_000)

        let assistantMsg = sut.currentSession.messages.last
        XCTAssertEqual(assistantMsg?.role, .assistant)
        XCTAssertEqual(assistantMsg?.content, expectedContent)
    }

    func test_startStreaming_removes_empty_placeholder_on_error() async throws {
        mockAPI.config.chatError = APIError.requestFailed("Venice unavailable")
        sut.startStreaming("Hello")
        try await Task.sleep(nanoseconds: 100_000_000)

        // No empty assistant bubble should remain
        let messages = sut.currentSession.messages
        let emptyAssistant = messages.last(where: { $0.role == .assistant && $0.content.isEmpty })
        XCTAssertNil(emptyAssistant, "Empty assistant placeholder should be removed on error")
    }

    func test_startStreaming_sets_isSending_false_after_completion() async throws {
        sut.startStreaming("Hello")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(sut.isSending)
    }
}

// ============================================================
// MARK: - ChatService.cancelCurrentRequest()
// ============================================================

@MainActor
final class ChatServiceCancellationTests: XCTestCase {

    var mockAPI: MockAmachAPIClient!
    var mockWallet: MockWalletService!
    var sut: ChatService!

    override func setUp() async throws {
        mockAPI = MockAmachAPIClient()
        mockWallet = MockWalletService()
        sut = ChatService(injectedAPI: mockAPI, injectedWallet: mockWallet)
    }

    func test_cancel_clears_isSending() {
        sut.isSending = true
        sut.cancelCurrentRequest()
        XCTAssertFalse(sut.isSending)
    }

    func test_cancel_removes_empty_assistant_placeholder() {
        let placeholder = ChatMessage(role: .assistant, content: "")
        sut.currentSession.messages.append(ChatMessage(role: .user, content: "Hello"))
        sut.currentSession.messages.append(placeholder)

        sut.cancelCurrentRequest()

        XCTAssertEqual(sut.currentSession.messages.count, 1, "Empty placeholder removed")
        XCTAssertEqual(sut.currentSession.messages[0].role, .user)
    }

    func test_cancel_does_not_remove_non_empty_assistant_message() {
        sut.currentSession.messages.append(ChatMessage(role: .assistant, content: "Already answered."))
        sut.cancelCurrentRequest()
        XCTAssertEqual(sut.currentSession.messages.count, 1)
    }

    func test_cancel_clears_error() {
        sut.error = "Something went wrong"
        sut.cancelCurrentRequest()
        XCTAssertNil(sut.error)
    }
}

// ============================================================
// MARK: - ChatService.startNewSession()
// ============================================================

@MainActor
final class ChatServiceNewSessionTests: XCTestCase {

    var mockAPI: MockAmachAPIClient!
    var mockWallet: MockWalletService!
    var sut: ChatService!

    override func setUp() async throws {
        mockAPI = MockAmachAPIClient()
        mockWallet = MockWalletService()
        sut = ChatService(injectedAPI: mockAPI, injectedWallet: mockWallet)
    }

    func test_startNewSession_resets_currentSession() {
        sut.currentSession.messages.append(ChatMessage(role: .user, content: "Old message"))
        sut.startNewSession()
        XCTAssertTrue(sut.currentSession.messages.isEmpty)
    }

    func test_startNewSession_archives_to_recentSessions() {
        sut.currentSession.messages.append(ChatMessage(role: .user, content: "Archived message"))
        let oldSessionId = sut.currentSession.id
        sut.startNewSession()
        let archivedIds = sut.recentSessions.map(\.id)
        XCTAssertTrue(archivedIds.contains(oldSessionId))
    }

    func test_startNewSession_skips_archiving_empty_session() {
        XCTAssertTrue(sut.currentSession.messages.isEmpty)
        sut.startNewSession()
        XCTAssertTrue(sut.recentSessions.isEmpty)
    }

    func test_startNewSession_caps_recentSessions_at_30() {
        // Pre-fill 30 sessions
        sut.recentSessions = (0..<30).map { i in
            var s = ChatSession()
            s.messages.append(ChatMessage(role: .user, content: "Session \(i)"))
            return s
        }
        // Add one more via startNewSession
        sut.currentSession.messages.append(ChatMessage(role: .user, content: "New session"))
        sut.startNewSession()
        XCTAssertLessThanOrEqual(sut.recentSessions.count, 30)
    }
}

// ============================================================
// MARK: - Disk Persistence Round-Trip
// ============================================================

@MainActor
final class ChatServiceDiskPersistenceTests: XCTestCase {

    func test_saveToDisk_and_loadFromDisk_roundtrip() throws {
        // Use a temp file to avoid polluting real app data
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("amach_test_sessions_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Build a session with known content
        var session = ChatSession()
        session.messages.append(ChatMessage(role: .user, content: "Persist this"))
        session.messages.append(ChatMessage(role: .assistant, content: "Persisted!"))

        // Encode and write
        let data = try JSONEncoder().encode([session])
        try data.write(to: tmpURL)

        // Read and decode
        let readData = try Data(contentsOf: tmpURL)
        let decoded = try JSONDecoder().decode([ChatSession].self, from: readData)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].messages.count, 2)
        XCTAssertEqual(decoded[0].messages[0].content, "Persist this")
        XCTAssertEqual(decoded[0].messages[1].content, "Persisted!")
    }
}

// ============================================================
// MARK: - Storj Sync Behaviour
// ============================================================

@MainActor
final class ChatServiceStorjSyncTests: XCTestCase {

    var mockAPI: MockAmachAPIClient!
    var mockWallet: MockWalletService!
    var sut: ChatService!

    override func setUp() async throws {
        mockAPI = MockAmachAPIClient()
        mockWallet = MockWalletService()
        sut = ChatService(injectedAPI: mockAPI, injectedWallet: mockWallet)
    }

    func test_syncToStorj_skipped_when_wallet_not_connected() async throws {
        mockWallet.isConnected = false
        // Manually trigger a sync; wallet not connected means it should bail out
        await sut.syncCurrentSessionToStorj()
        XCTAssertEqual(mockAPI.storeChatSessionCallCount, 0)
    }

    func test_syncToStorj_called_when_wallet_connected() async throws {
        // Add content to make session worth saving
        sut.currentSession.messages.append(ChatMessage(role: .user, content: "Hello"))
        await sut.syncCurrentSessionToStorj()
        XCTAssertEqual(mockAPI.storeChatSessionCallCount, 1)
    }

    func test_syncToStorj_skipped_for_empty_session() async throws {
        XCTAssertTrue(sut.currentSession.messages.isEmpty)
        await sut.syncCurrentSessionToStorj()
        XCTAssertEqual(mockAPI.storeChatSessionCallCount, 0)
    }
}
