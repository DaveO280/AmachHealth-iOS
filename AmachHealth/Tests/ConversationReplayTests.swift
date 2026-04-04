// ConversationReplayTests.swift
// AmachHealthTests
//
// Validates Luma replay JSON decoding (embedded + Documents shape).

import XCTest
@testable import AmachHealth

final class ConversationReplayTests: XCTestCase {

    func testEmbeddedReplayFixtureDecodes() throws {
        let data = try LumaConversationReplay.loadFixtureData()
        let root = try LumaConversationReplay.decode(data)
        XCTAssertEqual(root.sessions.count, 3)
        XCTAssertEqual(root.sessions.last?.messages.count, 2)
        XCTAssertEqual(root.memory?.facts.count, 3)
        XCTAssertEqual(root.memory?.summaries.count, 2)
    }

    func testReplaySessionsPreserveTimestamps() throws {
        let data = try LumaConversationReplay.loadFixtureData()
        let root = try LumaConversationReplay.decode(data)
        let session = try XCTUnwrap(root.sessions.first)
        let msg = try XCTUnwrap(session.messages.first)
        XCTAssertEqual(msg.role, .user)
        XCTAssertTrue(msg.content.contains("HRV"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(cal.component(.month, from: msg.timestamp), 3)
        XCTAssertEqual(cal.component(.day, from: msg.timestamp), 1)
    }
}
