// LumaPromptAssemblerTests.swift
// AmachHealthTests
//
// The phone's prompt assembly must match the website's /api/ai/chat for the
// same input. LumaPromptCases is the website's fixture
// (src/lib/luma/__fixtures__/luma-prompt-cases.json, copied by
// scripts/sync-luma-prompts.py): inputs and the messages the TypeScript
// builds for them.

import XCTest
import CryptoKit
@testable import AmachHealth

final class LumaPromptAssemblerTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            struct Input: Decodable {
                struct Block: Decodable { let type: String; let content: String }
                struct Report: Decodable { let type: String?; let title: String?; let date: String?; let content: String }
                enum Lab: Decodable {
                    case text(String), reports([Report])
                    init(from decoder: Decoder) throws {
                        let c = try decoder.singleValueContainer()
                        if let s = try? c.decode(String.self) { self = .text(s) } else { self = .reports(try c.decode([Report].self)) }
                    }
                }
                let message: String
                let contextBlocks: [Block]?
                let labData: Lab?
                let history: [AIChatHistoryMessage]?
            }
            let name: String
            let input: Input
            let messages: [LumaPromptMessage]
        }
        let configSha256: String
        let config: String
        let cases: [Case]
    }

    private func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(LumaPromptCases.json.utf8))
    }

    private func input(_ i: Fixture.Case.Input) -> LumaPromptInput {
        let lab: LumaLabData? = i.labData.map {
            switch $0 {
            case .text(let s): return .text(s)
            case .reports(let r): return .reports(r.map { LumaLabReport(type: $0.type, title: $0.title, date: $0.date, content: $0.content) })
            }
        }
        return LumaPromptInput(message: i.message,
                               contextBlocks: i.contextBlocks?.map { ContextBlock(type: $0.type, content: $0.content) },
                               labData: lab,
                               history: i.history ?? [])
    }

    func test_matches_the_website_for_every_fixture_case() throws {
        let fixture = try fixture()
        let assembler = LumaPromptAssembler(config: LumaPromptConfigStore.bundled)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 7)
        for c in fixture.cases {
            let got = assembler.messages(for: input(c.input))
            XCTAssertEqual(got.count, c.messages.count, c.name)
            for (i, (g, want)) in zip(got, c.messages).enumerated() {
                XCTAssertEqual(g, want, "\(c.name) message \(i)")
            }
        }
    }

    func test_bundled_config_is_the_fixtures_config() throws {
        let fixture = try fixture()
        XCTAssertEqual(LumaPromptConfig.bundledJSON, fixture.config)
        XCTAssertEqual(LumaPromptConfig.bundledSHA256, fixture.configSha256)
        let hash = SHA256.hash(data: Data(LumaPromptConfig.bundledJSON.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, LumaPromptConfig.bundledSHA256)
        XCTAssertEqual(LumaPromptConfigStore.bundled.historyLimit, 20)
    }

    func test_first_sentence_follows_javascript() {
        let f = { LumaPromptAssembler.firstSentence($0, maxUTF16: 120) }
        XCTAssertEqual(f("TSH 4.8 mIU/L. Recheck."), "TSH 4.8 mIU/L.")
        XCTAssertEqual(f("Done.\u{00A0}Next"), "Done.")          // NBSP is JS whitespace
        XCTAssertEqual(f("Bien.\r\nEnsuite"), "Bien.")           // "\r" stays, then splits
        XCTAssertEqual(f("Line one\nline two. End"), "Line one line two.")
        XCTAssertEqual(f(String(repeating: "x", count: 200)).count, 120)
        // 120 UTF-16 units, not 120 characters.
        XCTAssertEqual(LumaPromptAssembler.firstSentence("😴😴😴", maxUTF16: 4), "😴😴")
    }

    func test_wire_messages_have_one_system_message_first() throws {
        let fixture = try fixture()
        let assembler = LumaPromptAssembler(config: LumaPromptConfigStore.bundled)
        for c in fixture.cases {
            let full = assembler.messages(for: input(c.input))
            let wire = LumaPromptAssembler.singleSystemMessage(full)
            XCTAssertEqual(wire.filter { $0.role == .system }.count, 1, c.name)
            XCTAssertEqual(wire.first?.role, .system, c.name)
            XCTAssertEqual(wire.first?.content,
                           full.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n"), c.name)
            XCTAssertEqual(Array(wire.dropFirst()), full.filter { $0.role != .system }, c.name)
        }
    }

    // MARK: - Served config

    private func payload(_ config: String, sha: String? = nil) -> Data {
        let hash = sha ?? SHA256.hash(data: Data(config.utf8)).map { String(format: "%02x", $0) }.joined()
        return try! JSONSerialization.data(withJSONObject: ["sha256": hash, "config": config])
    }

    func test_served_config_must_match_its_hash() {
        let good = payload(LumaPromptConfig.bundledJSON)
        XCTAssertEqual(LumaPromptConfigStore.verify(good, requirePinned: true), LumaPromptConfigStore.bundled)
        let wrong = payload(LumaPromptConfig.bundledJSON, sha: String(repeating: "0", count: 64))
        XCTAssertNil(LumaPromptConfigStore.verify(wrong, requirePinned: false))
    }

    func test_release_builds_take_only_pinned_configs() {
        let edited = LumaPromptConfig.bundledJSON.replacingOccurrences(of: "You are Luma", with: "You are Bob")
        XCTAssertNil(LumaPromptConfigStore.verify(payload(edited), requirePinned: true))
        XCTAssertEqual(LumaPromptConfigStore.verify(payload(edited), requirePinned: false)?.systemPrompt.hasPrefix("You are Bob"), true)
    }
}
