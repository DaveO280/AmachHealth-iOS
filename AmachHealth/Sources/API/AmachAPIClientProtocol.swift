// AmachAPIClientProtocol.swift
// AmachHealth
//
// Protocol abstracting AmachAPIClient for dependency injection in tests.
// AmachAPIClient conforms via AmachAPIClient+Protocol.swift.
// MockAmachAPIClient in Tests/ conforms for unit testing.

import Foundation

/// Covers the chat methods ChatService relies on.
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
}

// Default parameter values for protocol methods.
// Swift protocols don't support default values directly, so we provide
// them via an extension to match AmachAPIClient's concrete defaults.
extension AmachAPIClientProtocol {
    func sendChatMessage(
        _ message: String,
        history: [AIChatHistoryMessage],
        context: AIChatContext? = nil,
        mode: ChatMode = .quick
    ) async throws -> AIChatResponse {
        try await sendChatMessage(message, history: history, context: context, mode: mode)
    }

    func streamLumaChat(
        _ message: String,
        history: [AIChatHistoryMessage],
        context: AIChatContext? = nil,
        screen: String? = nil,
        metric: String? = nil,
        mode: ChatMode = .quick
    ) -> AsyncThrowingStream<String, Error> {
        streamLumaChat(message, history: history, context: context, screen: screen, metric: metric, mode: mode)
    }
}

// MARK: - AmachAPIClient conformance (retroactive)
extension AmachAPIClient: AmachAPIClientProtocol {}
