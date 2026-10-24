// LumaMemoryTimelineTests.swift
// AmachHealthTests
//
// Memory facts and chat summaries drawn from a timeline entry name it, and are
// forgotten when the entry is deleted or edited, so Luma doesn't keep treating a
// removed event as real.

import XCTest
import GRDB
@testable import AmachHealth

@MainActor
final class LumaMemoryTimelineTests: XCTestCase {

    private var dir: URL!
    private let memory = ConversationMemoryStore.shared
    private let timeline = TimelineService.shared

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("luma-memory-timeline-\(UUID().uuidString)")
        BackupService.autoRunEnabled = false
        StorjImportService.autoRunEnabled = false
        let key = WalletEncryptionKey(walletAddress: WalletDecryptorFixtures.walletAddress,
                                      encryptionKey: WalletDecryptorFixtures.encryptionKey, signature: "0x", timestamp: 0)
        LocalVault.shared.open(walletKey: key, directory: dir)
    }

    override func tearDown() async throws {
        LocalVault.shared.close(forget: true)
        BackupService.autoRunEnabled = true
        StorjImportService.autoRunEnabled = true
        try? FileManager.default.removeItem(at: dir)
    }

    private func fatigueEvent(notes: String = "Less tired in the afternoons") -> TimelineEvent {
        TimelineEvent(
            id: "evt_qa_fatigue",
            eventType: .conditionImproved,
            timestamp: Date(),
            data: ["condition": "QA check fatigue", "notes": notes],
            metadata: TimelineEventMetadata(platform: "ios", version: "1", source: .userEntered),
            anomalyType: nil, metricType: nil, direction: nil, deviationPct: nil, resolvedAt: nil, attestationTxHash: nil
        )
    }

    private static let fatigueFact = "Experienced fatigue (tracked as a condition, noted as improved)"

    /// Answers the extraction prompts: one fact about the timeline entry, one not.
    private func memoryAPI() -> MockAmachAPIClient {
        let api = MockAmachAPIClient()
        api.config.chatResponder = { prompt in
            if prompt.contains("Analyze the conversation and extract") {
                return #"{"facts":[{"category":"condition","value":"\#(Self.fatigueFact)","event":"T1"},"#
                    + #"{"category":"goal","value":"Sleep 8 hours a night","context":"chat"}]}"#
            }
            if prompt.contains("Create a brief summary") {
                return #"{"summary":"Talked about fatigue.","topics":["fatigue"],"importance":"medium","events":["T1"]}"#
            }
            return nil
        }
        return api
    }

    /// Add the event, discuss it, and read the chat for memory.
    private func rememberChatAboutFatigue() async throws -> (ChatService, MockAmachAPIClient) {
        // An earlier chat, not about the entry.
        memory.upsert(facts: [], summary: SessionSummary(id: UUID(), date: Date().addingTimeInterval(-3600),
                                                         summary: "Planned a zone 2 cardio block.", topics: ["training"],
                                                         importance: .medium, messageCount: 4))
        try await timeline.addEvent(fatigueEvent())
        let api = memoryAPI()
        let sut = ChatService(injectedAPI: api, injectedWallet: MockWalletService(), injectedVault: LocalVault.shared.database)
        var session = ChatSession()
        session.messages = [ChatMessage(role: .user, content: "My fatigue improved, I logged it on the timeline. I want 8 hours of sleep."),
                            ChatMessage(role: .assistant, content: "Good to see the improvement.")]
        await sut.extractSessionMemory(from: session)
        return (sut, api)
    }

    private func memoryBlock() throws -> String {
        HealthContextBuilder.formatMemory(try XCTUnwrap(memory.buildMemoryCapsule(mode: .deep)))
    }

    func test_extraction_links_a_fact_to_the_timeline_entry_it_came_from() async throws {
        let (_, api) = try await rememberChatAboutFatigue()

        let prompt = try XCTUnwrap(api.sentChatMessages.first { $0.contains("Analyze the conversation and extract") })
        XCTAssertTrue(prompt.contains("T1 Condition Improved: QA check fatigue ("), prompt)
        XCTAssertTrue(prompt.contains("Do not store a fact that only restates a timeline entry"), prompt)

        let summaryPrompt = try XCTUnwrap(api.sentChatMessages.first { $0.contains("Create a brief summary") })
        XCTAssertTrue(summaryPrompt.contains("T1 Condition Improved: QA check fatigue ("), summaryPrompt)

        let fatigue = try XCTUnwrap(memory.facts.first { $0.value == Self.fatigueFact })
        XCTAssertEqual(fatigue.sourceEventId, "evt_qa_fatigue")
        XCTAssertNil(memory.facts.first { $0.value == "Sleep 8 hours a night" }?.sourceEventId)
        XCTAssertEqual(memory.summaries.first { $0.summary == "Talked about fatigue." }?.sourceEventIds, ["evt_qa_fatigue"])

        // The links are kept in the vault.
        memory.vaultDidChange()
        XCTAssertEqual(memory.facts.first { $0.value == Self.fatigueFact }?.sourceEventId, "evt_qa_fatigue")
        XCTAssertEqual(memory.summaries.first { $0.summary == "Talked about fatigue." }?.sourceEventIds, ["evt_qa_fatigue"])
    }

    func test_deleting_the_event_keeps_its_fact_out_of_lumas_context() async throws {
        let (sut, api) = try await rememberChatAboutFatigue()
        XCTAssertTrue(try memoryBlock().contains("Experienced fatigue"))
        XCTAssertTrue(try memoryBlock().contains("Talked about fatigue."))

        try await timeline.deleteEvent(id: "evt_qa_fatigue")

        let fatigue = try XCTUnwrap(memory.facts.first { $0.value == Self.fatigueFact })
        XCTAssertFalse(fatigue.isActive)
        XCTAssertNotNil(fatigue.retiredAt)
        let block = try memoryBlock()
        XCTAssertFalse(block.contains("Experienced fatigue"), block)
        XCTAssertFalse(block.contains("Talked about fatigue."), "the chat about it is forgotten too: \(block)")
        XCTAssertTrue(block.contains("Sleep 8 hours a night"), "facts not from the entry stay")
        XCTAssertTrue(block.contains("Planned a zone 2 cardio block."), "other chats stay")

        // What reaches the backend in a new chat.
        sut.startNewSession()
        await sut.send("Is my fatigue still on my timeline?")
        let sent = try XCTUnwrap(api.lastChatContext?.contextBlocks?.first { $0.type == "memory" }?.content)
        XCTAssertFalse(sent.contains("Experienced fatigue"), sent)
        XCTAssertFalse(sent.contains("Talked about fatigue."), sent)

        // Survives a reload from the vault.
        memory.vaultDidChange()
        XCTAssertEqual(memory.facts.first { $0.value == Self.fatigueFact }?.isActive, false)
        XCTAssertFalse(memory.summaries.contains { $0.summary == "Talked about fatigue." })
    }

    func test_editing_the_event_retires_facts_drawn_from_the_old_version() async throws {
        _ = try await rememberChatAboutFatigue()

        try await timeline.updateEvent(fatigueEvent(notes: "Actually back to feeling tired"))

        XCTAssertEqual(memory.facts.first { $0.value == Self.fatigueFact }?.isActive, false)
        XCTAssertFalse(try memoryBlock().contains("Experienced fatigue"))
        XCTAssertFalse(try memoryBlock().contains("Talked about fatigue."))
        XCTAssertTrue(timeline.events.contains { $0.data["notes"] == "Actually back to feeling tired" },
                      "the edited event is what the timeline block carries")
    }

    func test_saving_an_unchanged_event_keeps_the_fact() async throws {
        _ = try await rememberChatAboutFatigue()
        try await timeline.updateEvent(try XCTUnwrap(timeline.events.first { $0.id == "evt_qa_fatigue" }))
        XCTAssertEqual(memory.facts.first { $0.value == Self.fatigueFact }?.isActive, true)
        XCTAssertTrue(memory.summaries.contains { $0.summary == "Talked about fatigue." })
    }

    func test_memory_block_says_the_timeline_is_the_record_of_events() throws {
        let mem = AIChatMemoryCapsule(activeGoals: [], activeConcerns: [], medications: [], conditions: ["Has asthma (noted Oct 2026)"],
                                      recentSessionNotes: [])
        XCTAssertTrue(HealthContextBuilder.formatMemory(mem).contains("the timeline is the record"))
    }

    func test_v3_adds_the_source_columns_and_keeps_existing_memory() throws {
        let queue = try DatabaseQueue()
        var upToV2 = DatabaseMigrator()
        upToV2.registerMigration("v1") { db in
            try db.execute(sql: VaultDatabase.Schema.v1)
            try VaultDatabase.recordSchemaVersion(1, in: db)
        }
        upToV2.registerMigration("v2") { db in
            try db.execute(sql: VaultDatabase.Schema.v2)
            try VaultDatabase.recordSchemaVersion(2, in: db)
        }
        try upToV2.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO memory_facts (id, category, value, identified_at, is_active)
                VALUES ('\(UUID().uuidString)', 'goal', 'Run a 10k', 1, 1)
                """)
            try db.execute(sql: """
                INSERT INTO memory_summaries (id, date, summary, topics_json, importance, message_count)
                VALUES ('\(UUID().uuidString)', 1, 'Talked about running.', '[]', 'low', 2)
                """)
        }
        try VaultDatabase.migrator.migrate(queue)
        let row = try queue.read { db in try MemoryFactRow.fetchOne(db) }
        XCTAssertEqual(row?.value, "Run a 10k")
        XCTAssertNil(row?.sourceEventId)
        let summary = try queue.read { db in try MemorySummaryRow.fetchOne(db) }
        XCTAssertEqual(summary?.summary, "Talked about running.")
        XCTAssertNil(summary?.sourceEventIdsJson)
    }
}
