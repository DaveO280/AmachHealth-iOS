// LumaPromptAssembler.swift
// AmachHealth
//
// Builds every message for one Luma turn on the phone, for end-to-end-
// encrypted chat (VENICE-E2EE.md). It reproduces what the website's
// /api/ai/chat builds (Amach-Website src/lib/luma/chatPrompt.ts), in order:
//   1. the system prompt,
//   2. the phone's contextBlocks, each as its own system message,
//   3. the labData wrapper,
//   4. the last 20 history messages,
//   5. the "[Conversation context]" summary of earlier assistant turns,
//   6. the user turn.
// LumaPromptAssemblerTests replays the website's fixture to keep the two
// identical. The prompt text comes from GET /api/ai/prompts, with a bundled
// copy as the fallback (LumaPromptConfig+Bundled.swift).
//
// The server's legacy typed-field summary (buildContextMessage) isn't ported:
// the app never sends those fields, so on the server it always comes out
// empty for iOS. The app also doesn't send labData today (labs travel as
// context blocks), but the wrapper is here so the two stay the same.

import Foundation

/// Prompt text and limits, as served by GET /api/ai/prompts.
struct LumaPromptConfig: Decodable, Equatable {
    struct ConversationSummary: Decodable, Equatable {
        let minAssistantTurns: Int
        let maxTurns: Int
        /// Each turn's first sentence is cut to this many UTF-16 code units
        /// (JavaScript string length).
        let maxCharsPerTurn: Int
        let header: String
        let footer: String
    }

    let version: Int
    let systemPrompt: String
    let labDataPreamble: String
    let historyLimit: Int
    let conversationSummary: ConversationSummary
}

struct LumaPromptMessage: Equatable, Codable {
    enum Role: String, Codable { case system, user, assistant }
    let role: Role
    let content: String
}

/// One report forwarded as labData.
struct LumaLabReport: Equatable {
    var type: String?
    var title: String?
    var date: String?
    var content: String
}

enum LumaLabData: Equatable {
    case text(String)
    case reports([LumaLabReport])
}

/// Everything the phone has for one turn, before assembly.
struct LumaPromptInput {
    var message: String
    var contextBlocks: [ContextBlock]? = nil
    var labData: LumaLabData? = nil
    var history: [AIChatHistoryMessage] = []
}

struct LumaPromptAssembler {
    let config: LumaPromptConfig

    func messages(for input: LumaPromptInput) -> [LumaPromptMessage] {
        var out = [LumaPromptMessage(role: .system, content: config.systemPrompt)]

        for block in input.contextBlocks ?? [] {
            out.append(LumaPromptMessage(role: .system, content: block.content))
        }

        if let lab = labContent(input.labData), !lab.isEmpty {
            out.append(LumaPromptMessage(role: .system, content: "\(config.labDataPreamble)\n\n\(lab)"))
        }

        // History roles are the app's own ("user" / "assistant"); anything
        // else would be refused by the relay, so it's dropped here.
        let history = input.history.compactMap { m in
            LumaPromptMessage.Role(rawValue: m.role).map { LumaPromptMessage(role: $0, content: m.content) }
        }
        out.append(contentsOf: history.suffix(config.historyLimit))
        // The summary covers all history sent, not only the window above.
        if let summary = conversationSummary(history) {
            out.append(LumaPromptMessage(role: .system, content: summary))
        }

        out.append(LumaPromptMessage(role: .user, content: input.message))
        return out
    }

    /// The messages as sent end to end encrypted: one system message holding
    /// every system part in order (blank line between), then the rest.
    /// Venice's API layer merges system messages before they reach the
    /// enclave, which corrupts ciphertext: two encrypted system messages fail
    /// with "E2EE decryption failed" (phala) or "Encrypted field is not valid
    /// hex" (near-ai), adjacent or not (verified 2026-10-23). So the phone
    /// merges them itself, before encrypting.
    static func singleSystemMessage(_ messages: [LumaPromptMessage]) -> [LumaPromptMessage] {
        let system = messages.filter { $0.role == .system }.map(\.content)
        let rest = messages.filter { $0.role != .system }
        guard !system.isEmpty else { return rest }
        return [LumaPromptMessage(role: .system, content: system.joined(separator: "\n\n"))] + rest
    }

    // MARK: - labData

    private func labContent(_ labData: LumaLabData?) -> String? {
        switch labData {
        case .none: return nil
        case .text(let text): return text
        case .reports(let reports):
            // An entry without content has nothing to show (the server falls
            // back to dumping the raw entry, which the app never sends).
            return reports.filter { !$0.content.isEmpty }.map { report in
                let header = [report.title, report.type, report.date]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " — ")
                return header.isEmpty ? report.content : "### \(header)\n\(report.content)"
            }.joined(separator: "\n\n")
        }
    }

    // MARK: - Conversation summary

    func conversationSummary(_ history: [LumaPromptMessage]) -> String? {
        let summary = config.conversationSummary
        let assistantTurns = history.filter { $0.role == .assistant }
        guard assistantTurns.count >= summary.minAssistantTurns else { return nil }
        let recent = assistantTurns.suffix(summary.maxTurns)
        let first = assistantTurns.count - recent.count
        let lines = recent.enumerated().map { i, message in
            "- Turn \(first + i + 1): \(Self.firstSentence(message.content, maxUTF16: summary.maxCharsPerTurn))"
        }.joined(separator: "\n")
        return "\(summary.header)\n\(lines)\n\n\(summary.footer)"
    }

    /// `content.replace(/\n/g, " ").split(/(?<=[.!?])\s/)[0].slice(0, max)`,
    /// as JavaScript evaluates it: newlines only (a "\r" stays), cut at the
    /// first JavaScript whitespace that follows . ! or ?, then the first `max`
    /// UTF-16 code units. A cut through a surrogate pair gives U+FFFD where
    /// JavaScript keeps a lone surrogate; replies that long without a
    /// sentence break, ending in an emoji at exactly that point, are rare.
    static func firstSentence(_ content: String, maxUTF16: Int) -> String {
        let flat = content.replacingOccurrences(of: "\n", with: " ")
        var scalars = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in flat.unicodeScalars {
            if let p = previous, p == "." || p == "!" || p == "?", isJavaScriptWhitespace(scalar) { break }
            scalars.append(scalar)
            previous = scalar
        }
        let sentence = String(scalars)
        let units = Array(sentence.utf16.prefix(maxUTF16))
        return String(decoding: units, as: UTF16.self)
    }

    /// JavaScript's `\s`: WhiteSpace and LineTerminator.
    static func isJavaScriptWhitespace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }
}
