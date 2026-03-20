// AmachAPIClientProtocol.swift
// AmachHealth
//
// Protocol abstracting AmachAPIClient for dependency injection in tests.
// AmachAPIClient conforms via AmachAPIClient+Protocol.swift.
// MockAmachAPIClient in Tests/ conforms for unit testing.

import Foundation

/// Covers the methods ChatService and HealthDataSyncService rely on.
/// Extend as needed when new API surface is added.
protocol AmachAPIClientProtocol {
    // MARK: - Chat
    func sendChatMessage(
        _ message: String,
        history: [AIChatHistoryMessage],
        context: AIChatContext?,
        mode: ChatMode
    ) async throws -> AIChatResponse

    func streamLumaChat(
        _ message: String,
        history: [AIChatHistoryMessage],
        context: AIChatContext?,
        screen: String?,
        metric: String?,
        mode: ChatMode
    ) -> AsyncThrowingStream<String, Error>

    func submitChatFeedback(rating: String, screen: String?, comment: String?) async throws

    // MARK: - Storj / Chat Session
    func storeChatSession(
        _ session: ChatSession,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> String

    func storeConversationMemory(
        facts: [CriticalFact],
        summaries: [SessionSummary],
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> String

    func listHealthData(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        dataType: String?
    ) async throws -> [StorjListItem]

    // MARK: - Health Summary
    func getHealthSummary(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> HealthSummary

    // MARK: - Profile
    func readProfile(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> ResolvedProfile?
}

// MARK: - AmachAPIClient conformance (retroactive)
extension AmachAPIClient: AmachAPIClientProtocol {}
