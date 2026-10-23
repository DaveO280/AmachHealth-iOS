// VeniceE2EESpike.swift
// AmachHealth
//
// DEBUG-only spike for VENICE-E2EE.md: sends one Luma-style turn, encrypted
// on the phone to a Venice enclave model, through the website's ciphertext
// relay (/api/ai/e2ee) and logs the decrypted reply. Launch with
//   -VeniceE2EESpike   (relay: $AMACH_E2EE_RELAY, default http://127.0.0.1:3123/api/ai/e2ee)
// Not wired into ChatService yet; see the migration plan in VENICE-E2EE.md.

#if DEBUG
import Foundation
import VeniceE2EE

enum VeniceE2EESpike {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-VeniceE2EESpike") }

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        let relay = URL(string: env["AMACH_E2EE_RELAY"] ?? "http://127.0.0.1:3123/api/ai/e2ee")!
        let client = VeniceE2EEClient(relayURL: relay)
        let messages = [
            VeniceE2EEMessage(role: .system, content: "You are Luma, Amach Health's AI health companion. Reply in two short sentences."),
            VeniceE2EEMessage(role: .user, content: env["AMACH_E2EE_SPIKE_MESSAGE"]
                ?? "My vitamin D is 21 ng/mL and my TSH is 4.8 mIU/L. Should I be worried?"),
        ]
        print("[E2EE spike] relay=\(relay.absoluteString)")
        do {
            let started = Date()
            var reply = ""
            for try await event in try await client.send(tier: "chat", messages: messages, maxTokens: 600) {
                switch event {
                case let .served(model, provider): print("[E2EE spike] served by \(model) (\(provider ?? "?"))")
                case let .delta(text): reply += text
                case .done: break
                }
            }
            let stats = await client.lastStats
            print("[E2EE spike] attempts=\(stats.attempts) skipped=\(stats.skipped.keys.sorted()) encryptedChunks=\(stats.encryptedChunks) plaintextChunks=\(stats.plaintextChunks) seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))")
            print("[E2EE spike] reply: \(reply)")
        } catch {
            print("[E2EE spike] FAILED: \(error)")
        }
    }
}
#endif
