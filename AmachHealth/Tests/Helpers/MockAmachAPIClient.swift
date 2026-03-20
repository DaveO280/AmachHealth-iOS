// MockAmachAPIClient.swift
// AmachHealthTests
//
// Configurable mock API client for unit-testing ChatService and related services.
// Inject via ChatService(api: MockAmachAPIClient(), wallet: MockWalletService()).

import Foundation
@testable import AmachHealth

// MARK: - Mock Configuration

/// Controls what the mock returns for each API method.
/// Set fields before calling ChatService methods under test.
struct MockAPIConfig {
    // Chat
    var chatResponse: AIChatResponse = .fixture(content: "Mock Luma response to your query.")
    var chatError: Error? = nil

    // Storj
    var storeChatSessionResult: String = "storj://mock-bucket/chat-session-1.enc"
    var storeChatSessionError: Error? = nil
    var listHealthDataResult: [StorjListItem] = []
    var listHealthDataError: Error? = nil
    var storeConversationMemoryResult: String = "storj://mock-bucket/memory.enc"
    var storeConversationMemoryError: Error? = nil

    // Health summary
    var healthSummaryResult: HealthSummary = .fixture()
    var healthSummaryError: Error? = nil

    // Profile
    var profileResult: ResolvedProfile? = .fixture()
    var profileError: Error? = nil

    // Feedback
    var feedbackError: Error? = nil
}

// MARK: - Mock API Client

/// Thread-safe (main actor since tests run on @MainActor ChatService).
@MainActor
final class MockAmachAPIClient: AmachAPIClientProtocol {
    var config = MockAPIConfig()

    // Call counts for assertion
    var sendChatMessageCallCount = 0
    var streamLumaChatCallCount = 0
    var storeChatSessionCallCount = 0
    var storeConversationMemoryCallCount = 0
    var listHealthDataCallCount = 0
    var getHealthSummaryCallCount = 0
    var readProfileCallCount = 0
    var submitFeedbackCallCount = 0

    // Captured arguments for inspection
    var lastChatMessage: String?
    var lastChatHistory: [AIChatHistoryMessage]?
    var lastChatContext: AIChatContext?
    var lastStoredSession: ChatSession?
    var lastFeedbackRating: String?

    // MARK: - Chat

    func sendChatMessage(
        _ message: String,
        history: [AIChatHistoryMessage],
        context: AIChatContext?,
        mode: ChatMode
    ) async throws -> AIChatResponse {
        sendChatMessageCallCount += 1
        lastChatMessage = message
        lastChatHistory = history
        lastChatContext = context
        if let error = config.chatError { throw error }
        return config.chatResponse
    }

    func streamLumaChat(
        _ message: String,
        history: [AIChatHistoryMessage],
        context: AIChatContext?,
        screen: String?,
        metric: String?,
        mode: ChatMode
    ) -> AsyncThrowingStream<String, Error> {
        streamLumaChatCallCount += 1
        lastChatMessage = message

        let response = config.chatResponse.content
        let error = config.chatError

        return AsyncThrowingStream { continuation in
            if let error = error {
                continuation.finish(throwing: error)
                return
            }
            // Yield word-by-word, matching production streaming behaviour
            let words = response.split(separator: " ", omittingEmptySubsequences: false)
            for (i, word) in words.enumerated() {
                let chunk = (i == 0 ? "" : " ") + word
                continuation.yield(String(chunk))
            }
            continuation.finish()
        }
    }

    func submitChatFeedback(rating: String, screen: String?, comment: String?) async throws {
        submitFeedbackCallCount += 1
        lastFeedbackRating = rating
        if let error = config.feedbackError { throw error }
    }

    // MARK: - Storj

    func storeChatSession(
        _ session: ChatSession,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> String {
        storeChatSessionCallCount += 1
        lastStoredSession = session
        if let error = config.storeChatSessionError { throw error }
        return config.storeChatSessionResult
    }

    func storeConversationMemory(
        facts: [CriticalFact],
        summaries: [SessionSummary],
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> String {
        storeConversationMemoryCallCount += 1
        if let error = config.storeConversationMemoryError { throw error }
        return config.storeConversationMemoryResult
    }

    func listHealthData(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        dataType: String?
    ) async throws -> [StorjListItem] {
        listHealthDataCallCount += 1
        if let error = config.listHealthDataError { throw error }
        return config.listHealthDataResult
    }

    // MARK: - Health Summary

    func getHealthSummary(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> HealthSummary {
        getHealthSummaryCallCount += 1
        if let error = config.healthSummaryError { throw error }
        return config.healthSummaryResult
    }

    // MARK: - Profile

    func readProfile(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> ResolvedProfile? {
        readProfileCallCount += 1
        if let error = config.profileError { throw error }
        return config.profileResult
    }
}

// MARK: - Test Fixtures

extension AIChatResponse {
    static func fixture(content: String = "Mock Luma response.") -> AIChatResponse {
        AIChatResponse(content: content, model: "mock-venice-v1")
    }
}

extension HealthSummary {
    static func fixture() -> HealthSummary {
        HealthSummary(
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000),
            metricsCount: 35,
            dateRange: HealthSummary.DateRange(start: "2024-01-01", end: "2024-12-31"),
            dailyAverages: ["heartRate": 62.4, "steps": 8200.0, "hrv": 45.0]
        )
    }
}

extension ResolvedProfile {
    static func fixture() -> ResolvedProfile {
        ResolvedProfile(
            birthDate: "1981-01-01",
            sex: "male",
            height: 66,
            weight: 163,
            source: "mock",
            updatedAt: 1_700_000_000,
            version: 1,
            isActive: true
        )
    }
}
