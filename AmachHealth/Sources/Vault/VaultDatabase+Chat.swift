// VaultDatabase+Chat.swift
// AmachHealth
//
// chat_sessions / chat_messages and memory_facts / memory_summaries.

import Foundation
import GRDB

extension VaultDatabase {

    // MARK: - Chat

    /// Write sessions and their messages. Messages not in a saved session are removed.
    func saveChatSessions(_ sessions: [ChatSession], currentId: UUID?, origin: String = "device") throws {
        try dbQueue.write { db in
            if let currentId {
                try db.execute(
                    sql: "UPDATE chat_sessions SET is_current = 0 WHERE is_current = 1 AND id != ?",
                    arguments: [currentId.uuidString]
                )
            }
            for session in sessions {
                try Self.write(session, isCurrent: session.id == currentId, origin: origin, db: db)
            }
        }
    }

    /// Insert sessions the vault doesn't have. Existing sessions are left as they are.
    func insertMissingChatSessions(_ sessions: [ChatSession], origin: String) throws -> Int {
        try dbQueue.write { db in
            var inserted = 0
            for session in sessions where try !ChatSessionRow.exists(db, key: session.id.uuidString) {
                try Self.write(session, isCurrent: false, origin: origin, db: db)
                inserted += 1
            }
            return inserted
        }
    }

    private static func write(_ session: ChatSession, isCurrent: Bool, origin: String, db: Database) throws {
        let existingOrigin = try String.fetchOne(
            db, sql: "SELECT origin FROM chat_sessions WHERE id = ?", arguments: [session.id.uuidString]
        )
        let sessionRow = ChatSessionRow(
            id: session.id.uuidString,
            createdAt: session.createdAt.unixMillis,
            updatedAt: session.updatedAt.unixMillis,
            isCurrent: isCurrent,
            healthSummary: session.healthSummary,
            rollingSummary: session.rollingSummary,
            storjUri: session.storjUri,
            origin: existingOrigin ?? origin
        )
        if try ChatSessionRow.fetchOne(db, key: sessionRow.id) != sessionRow {
            try sessionRow.save(db)
        }

        let keep = session.messages.map(\.id.uuidString)
        try ChatMessageRow
            .filter(Column("session_id") == session.id.uuidString && !keep.contains(Column("id")))
            .deleteAll(db)

        let encoder = VaultJSON.encoder
        for (index, message) in session.messages.enumerated() {
            let row = ChatMessageRow(
                id: message.id.uuidString,
                sessionId: session.id.uuidString,
                position: index,
                role: message.role.rawValue,
                content: message.content,
                createdAt: message.timestamp.unixMillis,
                metadataJson: message.metadata.flatMap { try? String(decoding: encoder.encode($0), as: UTF8.self) },
                feedback: message.feedback?.rawValue
            )
            // Skip unchanged rows so backup_state only moves for real edits.
            if let existing = try ChatMessageRow.fetchOne(db, key: row.id),
               existing.content == row.content, existing.position == row.position,
               existing.feedback == row.feedback, existing.metadataJson == row.metadataJson,
               existing.sessionId == row.sessionId {
                continue
            }
            try row.save(db)
        }
    }

    /// Current session (if any) and the most recent other sessions, newest first.
    func loadChatSessions(recentLimit: Int) throws -> (current: ChatSession?, recent: [ChatSession]) {
        try dbQueue.read { db in
            let current = try ChatSessionRow.filter(Column("is_current") == true).fetchOne(db)
            let recent = try ChatSessionRow
                .filter(Column("is_current") == false)
                .order(Column("updated_at").desc)
                .limit(recentLimit)
                .fetchAll(db)
            return (try current.map { try Self.session(from: $0, db: db) },
                    try recent.map { try Self.session(from: $0, db: db) })
        }
    }

    func chatSession(id: UUID) throws -> ChatSession? {
        try dbQueue.read { db in
            try ChatSessionRow.fetchOne(db, key: id.uuidString).map { try Self.session(from: $0, db: db) }
        }
    }

    func chatCounts() throws -> (sessions: Int, messages: Int) {
        try dbQueue.read { db in
            (try ChatSessionRow.fetchCount(db), try ChatMessageRow.fetchCount(db))
        }
    }

    private static func session(from row: ChatSessionRow, db: Database) throws -> ChatSession {
        let decoder = VaultJSON.decoder
        var session = ChatSession(id: UUID(uuidString: row.id) ?? UUID(), createdAt: Date(unixMillis: row.createdAt))
        session.updatedAt = Date(unixMillis: row.updatedAt)
        session.healthSummary = row.healthSummary
        session.rollingSummary = row.rollingSummary
        session.storjUri = row.storjUri
        session.messages = try ChatMessageRow
            .filter(Column("session_id") == row.id)
            .order(Column("position"))
            .fetchAll(db)
            .map { m in
                ChatMessage(
                    id: UUID(uuidString: m.id) ?? UUID(),
                    role: MessageRole(rawValue: m.role) ?? .assistant,
                    content: m.content,
                    timestamp: Date(unixMillis: m.createdAt),
                    metadata: m.metadataJson.flatMap { try? decoder.decode(ChatMessageMetadata.self, from: Data($0.utf8)) },
                    feedback: m.feedback.flatMap(MessageFeedback.init(rawValue:))
                )
            }
        return session
    }

    // MARK: - Conversation memory

    /// Replace the stored memory with exactly these facts and summaries.
    func replaceMemory(facts: [CriticalFact], summaries: [SessionSummary]) throws {
        try dbQueue.write { db in
            let factIds = facts.map(\.id.uuidString)
            try MemoryFactRow.filter(!factIds.contains(Column("id"))).deleteAll(db)
            for fact in facts {
                let row = MemoryFactRow(
                    id: fact.id.uuidString, category: fact.category.rawValue, value: fact.value,
                    context: fact.context, identifiedAt: fact.dateIdentified.unixMillis,
                    lastConfirmedAt: fact.lastConfirmed?.unixMillis, isActive: fact.isActive
                )
                if let existing = try MemoryFactRow.fetchOne(db, key: row.id),
                   existing.value == row.value, existing.context == row.context,
                   existing.lastConfirmedAt == row.lastConfirmedAt, existing.isActive == row.isActive {
                    continue
                }
                try row.save(db)
            }

            let summaryIds = summaries.map(\.id.uuidString)
            try MemorySummaryRow.filter(!summaryIds.contains(Column("id"))).deleteAll(db)
            for summary in summaries {
                let row = MemorySummaryRow(
                    id: summary.id.uuidString, date: summary.date.unixMillis, summary: summary.summary,
                    topicsJson: (try? String(decoding: JSONEncoder().encode(summary.topics), as: UTF8.self)) ?? "[]",
                    importance: summary.importance.rawValue, messageCount: summary.messageCount
                )
                // A session's summary is rewritten as the session grows.
                if let existing = try MemorySummaryRow.fetchOne(db, key: row.id),
                   existing.date == row.date, existing.summary == row.summary,
                   existing.messageCount == row.messageCount {
                    continue
                }
                try row.save(db)
            }
        }
    }

    func loadMemory() throws -> ConversationMemoryStorjPayload {
        try dbQueue.read { db in
            let facts = try MemoryFactRow.order(Column("identified_at")).fetchAll(db).compactMap { row -> CriticalFact? in
                guard let category = FactCategory(rawValue: row.category), let id = UUID(uuidString: row.id) else { return nil }
                return CriticalFact(
                    id: id, category: category, value: row.value, context: row.context,
                    dateIdentified: Date(unixMillis: row.identifiedAt), isActive: row.isActive,
                    lastConfirmed: row.lastConfirmedAt.map(Date.init(unixMillis:))
                )
            }
            let summaries = try MemorySummaryRow.order(Column("date")).fetchAll(db).compactMap { row -> SessionSummary? in
                guard let id = UUID(uuidString: row.id),
                      let importance = MemoryImportance(rawValue: row.importance) else { return nil }
                let topics = (try? JSONDecoder().decode([String].self, from: Data(row.topicsJson.utf8))) ?? []
                return SessionSummary(
                    id: id, date: Date(unixMillis: row.date), summary: row.summary,
                    topics: topics, importance: importance, messageCount: row.messageCount
                )
            }
            return ConversationMemoryStorjPayload(facts: facts, summaries: summaries)
        }
    }

    func memoryCounts() throws -> (facts: Int, summaries: Int) {
        try dbQueue.read { db in (try MemoryFactRow.fetchCount(db), try MemorySummaryRow.fetchCount(db)) }
    }
}
