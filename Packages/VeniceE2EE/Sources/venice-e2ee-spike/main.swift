// venice-e2ee-spike
//
// Sends one encrypted Luma-style chat turn through the relay and prints the
// decrypted reply. Usage:
//   venice-e2ee-spike [relayURL] [message]
//   venice-e2ee-spike --attest <model>      (attestation check only)
// relayURL defaults to $AMACH_E2EE_RELAY or http://localhost:3123/api/ai/e2ee.

import Foundation
import VeniceE2EE

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--attest" {
    let model = args.count > 1 ? args[1] : "e2ee-glm-5-3-p"
    do {
        let key = try await VeniceAttestationVerifier().attest(model: model)
        print("attested \(model): provider=\(key.teeProvider ?? "?") key=\(key.publicKeyHex.prefix(18))… address=\(key.signingAddress) mrtd=\(key.mrTD.prefix(16))…")
    } catch {
        print("attestation FAILED for \(model): \(error)")
        exit(1)
    }
    exit(0)
}

let relay = URL(string: args.first ?? ProcessInfo.processInfo.environment["AMACH_E2EE_RELAY"]
                ?? "http://localhost:3123/api/ai/e2ee")!
let question = args.count > 1 ? args[1] : "My ferritin came back at 18 ng/mL. Is that low?"

// AMACH_HTTP_PROXY=host:port routes plain-HTTP traffic (the local relay hop)
// through a capture proxy; HTTPS (Venice attestation) still goes direct.
let session: URLSession = {
    guard let proxy = ProcessInfo.processInfo.environment["AMACH_HTTP_PROXY"],
          let colon = proxy.lastIndex(of: ":"), let port = Int(proxy[proxy.index(after: colon)...]) else {
        return .shared
    }
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [
        "HTTPEnable": 1, "HTTPProxy": String(proxy[..<colon]), "HTTPPort": port,
    ]
    return URLSession(configuration: config)
}()
let client = VeniceE2EEClient(relayURL: relay, session: session)
let messages = [
    VeniceE2EEMessage(role: .system, content: "You are Luma, Amach Health's AI health companion. Reply in two short sentences."),
    VeniceE2EEMessage(role: .user, content: question),
]

do {
    let started = Date()
    var reply = ""
    for try await event in try await client.send(tier: "chat", messages: messages, maxTokens: 600) {
        switch event {
        case let .served(model, provider): print("served by \(model) (\(provider ?? "?"))")
        case let .delta(text): reply += text
        case let .done(prompt, completion): print("usage: prompt=\(prompt ?? -1) completion=\(completion ?? -1)")
        }
    }
    let stats = await client.lastStats
    print("attempts=\(stats.attempts) skipped=\(stats.skipped.keys.sorted()) encryptedChunks=\(stats.encryptedChunks) plaintextChunks=\(stats.plaintextChunks) seconds=\(String(format: "%.1f", Date().timeIntervalSince(started)))")
    print("reply: \(reply)")
} catch {
    print("FAILED: \(error)")
    exit(1)
}
