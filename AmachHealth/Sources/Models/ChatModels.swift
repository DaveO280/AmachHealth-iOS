// ChatModels.swift
// AmachHealth
//
// Data models for the Cosaint AI chat feature

import Foundation

// MARK: - Chat Messages

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable {
    var id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date

    init(id: UUID = UUID(), role: MessageRole, content: String, timestamp: Date = .now) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

// MARK: - Chat Session

struct ChatSession: Identifiable, Codable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var messages: [ChatMessage]
    var storjUri: String?

    var displayTitle: String {
        messages.first(where: { $0.role == .user })?
            .content
            .prefix(50)
            .description
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "New Chat"
    }

    init(id: UUID = UUID(), createdAt: Date = .now) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.messages = []
    }
}

// MARK: - API Request: POST /api/ai/chat

struct AIChatRequest: Encodable {
    let message: String
    let context: AIChatContext?
    let history: [AIChatHistoryMessage]
    let options: AIChatOptions?
}

struct AIChatContext: Encodable {
    let metrics: AIChatMetrics?
    let dateRange: AIChatDateRange?
}

struct AIChatMetrics: Encodable {
    let steps: MetricContext?
    let heartRate: MetricContext?
    let hrv: MetricContext?
    let sleep: MetricContext?
    let exercise: MetricContext?
}

struct MetricContext: Encodable {
    let average: Double?
    let min: Double?
    let max: Double?
    let latest: Double?
    let trend: String? // "improving" | "stable" | "declining"
}

struct AIChatDateRange: Encodable {
    let start: String
    let end: String
}

struct AIChatHistoryMessage: Codable {
    let role: String
    let content: String
}

struct AIChatOptions: Encodable {
    let mode: String // "quick" | "deep"
}

// MARK: - API Response

struct AIChatResponse: Decodable {
    let content: String
    let usage: AIChatUsage?
    let model: String?
}

struct AIChatUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}
