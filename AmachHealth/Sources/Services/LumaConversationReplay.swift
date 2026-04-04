// LumaConversationReplay.swift
// AmachHealth
//
// Load longitudinal chat + memory fixtures (ISO8601 dates) for DEBUG analysis.
// Drop `luma_conversation_replay.json` into the app Documents folder to override
// the embedded sample; see `LumaReplayFixtureRoot` shape below.

import Foundation

// MARK: - Fixture model (JSON)

/// Root object for `luma_conversation_replay.json`.
///
/// `sessions`: chronological (oldest first). The **last** session becomes the active
/// chat; earlier sessions appear in **recent** history (newest-archived first, max 3).
/// `memory`: optional facts/summaries with **your** `dateIdentified` / `date` values
/// so retention and capsule ordering match production-like timelines.
struct LumaReplayFixtureRoot: Decodable {
    var sessions: [LumaReplaySessionDTO]
    var memory: ConversationMemoryStorjPayload?
}

struct LumaReplaySessionDTO: Decodable {
    var createdAt: Date
    var updatedAt: Date
    var messages: [LumaReplayMessageDTO]

    func makeChatSession() -> ChatSession {
        var s = ChatSession(id: UUID(), createdAt: createdAt)
        s.updatedAt = updatedAt
        s.messages = messages.map {
            ChatMessage(role: $0.role, content: $0.content, timestamp: $0.timestamp)
        }
        return s
    }
}

struct LumaReplayMessageDTO: Decodable {
    var role: MessageRole
    var content: String
    var timestamp: Date
}

// MARK: - Loader

enum LumaConversationReplay {

    static let replayFilename = "luma_conversation_replay.json"

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func decode(_ data: Data) throws -> LumaReplayFixtureRoot {
        try makeDecoder().decode(LumaReplayFixtureRoot.self, from: data)
    }

    /// Documents override, otherwise embedded sample.
    static func loadFixtureData() throws -> Data {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let fileURL = docs.appendingPathComponent(replayFilename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return try Data(contentsOf: fileURL)
        }
        guard let data = embeddedSampleJSON.data(using: .utf8) else {
            throw ReplayError.utf8EncodingFailed
        }
        return data
    }

    enum ReplayError: Error {
        case utf8EncodingFailed
    }

    #if DEBUG
    /// Applies decoded fixture to `ChatService` and `ConversationMemoryStore` and persists both.
    @MainActor
    static func apply(
        _ root: LumaReplayFixtureRoot,
        mergeMemory: Bool,
        chat: ChatService,
        memory: ConversationMemoryStore
    ) {
        let mapped = root.sessions.map { $0.makeChatSession() }
        guard let current = mapped.last else { return }
        let recent = Array(mapped.dropLast().reversed().prefix(3))
        chat.debugApplyReplaySessions(current: current, recent: recent)
        if let mem = root.memory {
            memory.debugApplyReplayMemory(mem, mergeIntoExisting: mergeMemory)
        }
    }

    @MainActor
    static func applyEmbeddedOrDocuments(mergeMemory: Bool) throws {
        let data = try loadFixtureData()
        let root = try decode(data)
        apply(root, mergeMemory: mergeMemory, chat: .shared, memory: .shared)
    }
    #endif

    /// Sample: three sessions on different days + memory with backdated facts/summaries.
    static let embeddedSampleJSON: String = """
    {
      "sessions": [
        {
          "createdAt": "2026-03-01T14:00:00Z",
          "updatedAt": "2026-03-01T14:03:00Z",
          "messages": [
            {
              "role": "user",
              "content": "I've been dragging after hard training days. HRV was 28 ms yesterday.",
              "timestamp": "2026-03-01T14:00:00Z"
            },
            {
              "role": "assistant",
              "content": "That pattern often shows accumulated stress. If HRV stays depressed for several days, consider backing off intensity until morning readings stabilize.",
              "timestamp": "2026-03-01T14:02:00Z"
            }
          ]
        },
        {
          "createdAt": "2026-03-03T09:00:00Z",
          "updatedAt": "2026-03-03T09:04:00Z",
          "messages": [
            {
              "role": "user",
              "content": "Trying to sleep earlier this week — aiming for 10:30pm lights out.",
              "timestamp": "2026-03-03T09:00:00Z"
            },
            {
              "role": "assistant",
              "content": "Consistency matters as much as duration. A fixed wind-down and the same wake time will help your HRV more than varying bedtimes.",
              "timestamp": "2026-03-03T09:03:00Z"
            }
          ]
        },
        {
          "createdAt": "2026-03-05T16:00:00Z",
          "updatedAt": "2026-03-05T16:05:00Z",
          "messages": [
            {
              "role": "user",
              "content": "Back to the training question — I'm on magnesium glycinate at night and want to add creatine. Any conflict?",
              "timestamp": "2026-03-05T16:00:00Z"
            },
            {
              "role": "assistant",
              "content": "Generally no direct conflict; creatine timing is flexible. Keep monitoring sleep if you shift dose timing — some people notice stimulation if taken late.",
              "timestamp": "2026-03-05T16:04:00Z"
            }
          ]
        }
      ],
      "memory": {
        "facts": [
          {
            "id": "A1B2C3D4-E5F6-4789-A012-345678901234",
            "category": "concern",
            "value": "Low HRV after intense training blocks",
            "context": "Mentioned in early March check-in",
            "dateIdentified": "2026-03-01T14:02:00Z",
            "isActive": true,
            "lastConfirmed": null
          },
          {
            "id": "B2C3D4E5-F6A7-4890-B123-456789012345",
            "category": "goal",
            "value": "Consistent 10:30pm sleep window",
            "context": "User goal for recovery",
            "dateIdentified": "2026-03-03T09:03:00Z",
            "isActive": true,
            "lastConfirmed": null
          },
          {
            "id": "C3D4E5F6-A7B8-4901-C234-567890123456",
            "category": "medication",
            "value": "Magnesium glycinate at night",
            "context": "Supplement stack",
            "dateIdentified": "2026-03-05T16:04:00Z",
            "isActive": true,
            "lastConfirmed": null
          }
        ],
        "summaries": [
          {
            "id": "D4E5F6A7-B8C9-4012-D345-678901234567",
            "date": "2026-03-01T14:03:00Z",
            "summary": "Discussed low energy after workouts and depressed HRV; agreed to watch recovery before adding load.",
            "topics": ["HRV", "recovery", "training"],
            "importance": "high",
            "messageCount": 2
          },
          {
            "id": "E5F6A7B8-C9D0-4123-E456-789012345678",
            "date": "2026-03-05T16:05:00Z",
            "summary": "Follow-up on sleep timing goals and supplement stack (magnesium, creatine).",
            "topics": ["sleep", "supplements"],
            "importance": "medium",
            "messageCount": 2
          }
        ]
      }
    }
    """
}
