// LumaPrivateChat.swift
// AmachHealth
//
// Luma chat, end to end encrypted (VENICE-E2EE.md, Phase 4a). The phone
// builds every message itself (LumaPromptAssembler), encrypts it to an
// attested Venice enclave key (Packages/VeniceE2EE) and sends it through the
// website's ciphertext relay, /api/ai/e2ee. Amach's servers only relay
// encrypted data. The relay is tied to the wallet: it takes the encrypted
// backup session token, earned by signing the "Amach backup access"
// challenge.
//
// Off by default (`LumaPrivateChat.isEnabled`); ChatService keeps the
// /api/ai/chat path when it's off. With it on there is no silent fallback to
// the plaintext route: a failure becomes Luma's "enclave busy" / "out of
// credit" note or an error, never a plaintext retry.

import Foundation
import CryptoKit
import VeniceE2EE

/// Where ChatService sends Luma turns. Tests inject a fake.
protocol LumaChatTransport: Sendable {
    /// Reply text as it arrives, leading whitespace trimmed. Throws
    /// APIError.enclaveBusy / .aiCreditExhausted for Luma's pause notes, and
    /// "Luma returned an empty response" when nothing came back.
    func stream(_ input: LumaPromptInput) -> AsyncThrowingStream<String, Error>
}

enum LumaPrivateChat {
    static let defaultsKey = "LumaE2EEChat"

    /// Off unless the `LumaE2EEChat` default is set (Settings, or the launch
    /// argument `-LumaE2EEChat YES`).
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// The ciphertext relay: $AMACH_E2EE_RELAY, else the API base URL's
    /// /api/ai/e2ee.
    static var relayURL: URL {
        if let env = ProcessInfo.processInfo.environment["AMACH_E2EE_RELAY"], let url = URL(string: env) {
            return url
        }
        return URL(string: AmachAPIClient.shared.apiBaseURL.absoluteString + "/api/ai/e2ee")!
    }

    /// The reply to an empty response, matching streamLumaChat's, so
    /// ChatService's retry-once applies to both paths.
    static let emptyResponse = APIError.requestFailed("Luma returned an empty response. Please try again.")

    /// Maps relay and attestation failures to the errors ChatService already
    /// turns into Luma's notes.
    static func mapError(_ error: Error) -> Error {
        switch error as? VeniceE2EEError {
        case .noAttestableModel:
            // Every enclave failed attestation: nothing was sent. Same note as
            // a full enclave.
            return APIError.enclaveBusy
        case let .relay(_, code, resetsAt) where code == APIError.aiCreditExhaustedCode:
            return APIError.aiCreditExhausted(
                resetsAt: resetsAt.flatMap { ISO8601DateFormatter.withFractionalSeconds.date(from: $0) })
        case let .relay(status, code, _) where code == APIError.enclaveBusyCode || status == 429:
            // 429: this wallet's relay limit; Luma's "give it a minute" fits.
            return APIError.enclaveBusy
        case let .relay(status, _, _):
            return APIError.httpError(statusCode: status)
        case .plaintextReply, .decryption, .malformedResponse:
            // Fail closed: a reply that wasn't encrypted to this request (or
            // can't be read) is never shown.
            return APIError.requestFailed("Luma's private connection couldn't be verified. Please try again.")
        case .none:
            return error
        }
    }
}

// MARK: - Transport

final class LumaE2EEChatTransport: LumaChatTransport, @unchecked Sendable {
    static let shared = LumaE2EEChatTransport()

    private let client: VeniceE2EEClient
    private let prompts: LumaPromptConfigStore

    init(client: VeniceE2EEClient = VeniceE2EEClient(relayURL: LumaPrivateChat.relayURL,
                                                       authorizer: LumaRelayAuthorizer()),
         prompts: LumaPromptConfigStore = .shared) {
        self.client = client
        self.prompts = prompts
    }

    func stream(_ input: LumaPromptInput) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let config = await prompts.current()
                    // Same messages as /api/ai/chat, system parts merged into one
                    // (Venice can't merge encrypted system messages itself).
                    let messages = LumaPromptAssembler.singleSystemMessage(
                        LumaPromptAssembler(config: config).messages(for: input))
                    // The wallet key never leaves the phone, encrypted or not.
                    try OutboundSecretGuard.check(JSONEncoder().encode(messages))
                    let wire = messages.map {
                        VeniceE2EEMessage(role: VeniceE2EEMessage.Role(rawValue: $0.role.rawValue)!, content: $0.content)
                    }
                    var started = false
                    for try await event in try await client.send(tier: "chat", messages: wire, temperature: 0.7) {
                        switch event {
                        case .delta(let text):
                            // Qwen opens with "\n\n"; trim until real text arrives.
                            let out = started ? text : String(text.drop(while: { $0.isWhitespace }))
                            guard !out.isEmpty else { continue }
                            started = true
                            continuation.yield(out)
                        case let .served(model, provider):
                            #if DEBUG
                            print("🔒 [Luma E2EE] served by \(model) (\(provider ?? "?"))")
                            #endif
                        case .done:
                            break
                        }
                    }
                    #if DEBUG
                    let stats = await client.lastStats
                    print("🔒 [Luma E2EE] attempts=\(stats.attempts) skipped=\(stats.skipped.keys.sorted()) " +
                          "encrypted=\(stats.encryptedChunks) plaintext=\(stats.plaintextChunks) " +
                          "reattested=\(stats.reattested) authRefreshed=\(stats.authRefreshed)")
                    #endif
                    if !started { throw LumaPrivateChat.emptyResponse }
                    continuation.finish()
                } catch {
                    #if DEBUG
                    print("🔒 [Luma E2EE] failed: \(error)")
                    #endif
                    continuation.finish(throwing: LumaPrivateChat.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Relay auth

/// The relay's bearer token: the encrypted-backup session token for the
/// connected wallet (2 h, signed challenge), shared machinery with backup.
actor LumaRelayAuthorizer: VeniceRelayAuthorizing {
    private var credentials: BackupCredentialsClient?

    func relayToken(refresh: Bool) async throws -> String {
        #if DEBUG
        // Local relay runs without a Privy session: a session token minted by
        // that relay for a throwaway test wallet.
        if let token = ProcessInfo.processInfo.environment["AMACH_E2EE_RELAY_TOKEN"], !token.isEmpty {
            return token
        }
        #endif
        guard let signer = await MainActor.run(body: { WalletBackupSigner() }) else {
            throw APIError.requestFailed("Connect your wallet to use Luma's private chat.")
        }
        if credentials?.walletAddress.lowercased() != signer.address.lowercased() {
            credentials = BackupCredentialsClient(signer: signer)
        }
        if refresh { credentials?.resetSession() }
        return try await credentials!.currentToken()
    }
}

// MARK: - Prompt config

/// The prompt text for on-phone assembly: GET /api/ai/prompts, refreshed at
/// most every 30 minutes, else the bundled copy. A served config is used
/// only if it hashes to the `sha256` it came with, and in release builds
/// only if that hash is one the app ships with (`pinnedSHA256`), so a
/// tampered server can't swap Luma's instructions. Debug builds take any
/// well-formed config so prompt edits can be tried before an app release.
actor LumaPromptConfigStore {
    static let shared = LumaPromptConfigStore()

    static let pinnedSHA256: Set<String> = [LumaPromptConfig.bundledSHA256]
    static let bundled: LumaPromptConfig = {
        try! JSONDecoder().decode(LumaPromptConfig.self, from: Data(LumaPromptConfig.bundledJSON.utf8))
    }()

    private let url: URL?
    private let session: URLSession
    private let requirePinned: Bool
    private var cached: (config: LumaPromptConfig, fetchedAt: Date)?

    init(url: URL? = URL(string: AmachAPIClient.shared.apiBaseURL.absoluteString + "/api/ai/prompts"),
         session: URLSession = .shared,
         requirePinned: Bool = LumaPromptConfigStore.isReleaseBuild) {
        self.url = url
        self.session = session
        self.requirePinned = requirePinned
    }

    static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    func current() async -> LumaPromptConfig {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < 1800 { return cached.config }
        let config = await fetch() ?? Self.bundled
        cached = (config, Date())
        return config
    }

    /// Checks a GET /api/ai/prompts body. Nil when malformed, mis-hashed or
    /// (in release) not pinned.
    nonisolated static func verify(_ data: Data, requirePinned: Bool) -> LumaPromptConfig? {
        struct Payload: Decodable { let sha256: String; let config: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let hash = SHA256.hash(data: Data(payload.config.utf8)).map { String(format: "%02x", $0) }.joined()
        guard hash == payload.sha256.lowercased() else { return nil }
        if requirePinned, !pinnedSHA256.contains(hash) { return nil }
        return try? JSONDecoder().decode(LumaPromptConfig.self, from: Data(payload.config.utf8))
    }

    private func fetch() async -> LumaPromptConfig? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.verify(data, requirePinned: requirePinned)
    }
}
