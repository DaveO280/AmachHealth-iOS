// VeniceE2EEClient.swift
// VeniceE2EE
//
// Sends a conversation to a Venice enclave model through Amach's ciphertext
// relay (POST /api/ai/e2ee?tier=…). The phone:
//   1. asks the relay which models the tier may use (no data involved),
//   2. attests each model directly with Venice and verifies it on-device,
//   3. encrypts every message once per distinct enclave key (models behind
//      the same gateway share a key) and sends all attempts in one request,
//      so the relay can fall back without ever holding plaintext,
//   4. decrypts the reply stream with a fresh per-request client key.
//
// The relay needs a wallet session (`authorizer`, Bearer token). A 401 gets
// one fresh token and one retry. When an enclave says it couldn't decrypt
// (its gateway key rotated), the relay names those models; the client drops
// their cached keys, attests again and retries once.

import Foundation

public struct VeniceE2EEMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case system, user, assistant }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public enum VeniceE2EEEvent: Sendable, Equatable {
    /// The relay picked this model (from the x-amach-model header).
    case served(model: String, teeProvider: String?)
    /// Decrypted reply text.
    case delta(String)
    case done(promptTokens: Int?, completionTokens: Int?)
}

public enum VeniceE2EEError: Error, Equatable {
    case noAttestableModel([String])
    /// The relay refused or failed the request. `resetsAt` (ISO 8601) comes
    /// with `ai_credit_exhausted`.
    case relay(status: Int, code: String?, resetsAt: String? = nil)
    case decryption
    /// A reply chunk arrived unencrypted; the request wasn't served by E2EE.
    case plaintextReply
    case malformedResponse
}

/// Attests one model's enclave key (VeniceAttestationVerifier in the app).
public protocol VeniceModelAttesting: Sendable {
    func attest(model: String, session: URLSession) async throws -> AttestedModelKey
}

extension VeniceAttestationVerifier: VeniceModelAttesting {}

/// Supplies the relay's bearer token (the wallet's backup session token).
public protocol VeniceRelayAuthorizing: Sendable {
    /// A token for the relay. `refresh` is true after the relay answered 401,
    /// so a cached token must not be reused.
    func relayToken(refresh: Bool) async throws -> String
}

public actor VeniceE2EEClient {
    public let relayURL: URL
    private let verifier: any VeniceModelAttesting
    private let authorizer: (any VeniceRelayAuthorizing)?
    private let session: URLSession
    private let attestationTTL: TimeInterval
    private var cache: [String: AttestedModelKey] = [:]
    /// Attestations in progress, so parallel requests (a report's sections)
    /// share one per model instead of each attesting it again.
    private var attesting: [String: Task<AttestedModelKey, Error>] = [:]

    /// Diagnostics from the last request (counts only, no content).
    public private(set) var lastStats = Stats()

    public struct Stats: Sendable, Equatable {
        public var attempts: [String] = []
        public var skipped: [String: String] = [:]
        public var encryptedChunks = 0
        public var plaintextChunks = 0
        /// Models re-attested because their enclave couldn't decrypt.
        public var reattested: [String] = []
        public var authRefreshed = false
    }

    public init(relayURL: URL,
                verifier: any VeniceModelAttesting = VeniceAttestationVerifier(),
                authorizer: (any VeniceRelayAuthorizing)? = nil,
                session: URLSession = .shared,
                attestationTTL: TimeInterval = 600) {
        self.relayURL = relayURL
        self.verifier = verifier
        self.authorizer = authorizer
        self.session = session
        self.attestationTTL = attestationTTL
    }

    // MARK: Model chain + attestation

    public func modelChain(tier: String) async throws -> [String] {
        let (data, response) = try await session.data(from: url(tier: tier))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [String] else {
            throw VeniceE2EEError.malformedResponse
        }
        return models
    }

    public func attestedKey(for model: String) async throws -> AttestedModelKey {
        if let cached = cache[model], Date().timeIntervalSince(cached.verifiedAt) < attestationTTL {
            return cached
        }
        if let pending = attesting[model] { return try await pending.value }
        let verifier = self.verifier, session = self.session
        let task = Task { try await verifier.attest(model: model, session: session) }
        attesting[model] = task
        defer { attesting[model] = nil }
        let key = try await task.value
        cache[model] = key
        return key
    }

    /// Drops a model's cached key (e.g. after Venice says it can't decrypt).
    public func invalidate(model: String) { cache[model] = nil }

    // MARK: Request

    public func send(tier: String,
                     messages: [VeniceE2EEMessage],
                     stream: Bool = true,
                     maxTokens: Int? = nil,
                     temperature: Double? = nil) async throws -> AsyncThrowingStream<VeniceE2EEEvent, Error> {
        lastStats = Stats()
        let chain = try await modelChain(tier: tier)
        var refreshAuth = false
        var reattested = false
        while true {
            do {
                return try await sendOnce(tier: tier, chain: chain, messages: messages, stream: stream,
                                          maxTokens: maxTokens, temperature: temperature, refreshAuth: refreshAuth)
            } catch let failure as RelayFailure {
                if failure.status == 401, authorizer != nil, !refreshAuth {
                    refreshAuth = true
                    lastStats.authRefreshed = true
                    continue
                }
                if !failure.staleKeyModels.isEmpty, !reattested {
                    // The gateway rotated its key: attest again, retry once.
                    reattested = true
                    failure.staleKeyModels.forEach { cache[$0] = nil }
                    lastStats.reattested = failure.staleKeyModels
                    continue
                }
                throw VeniceE2EEError.relay(status: failure.status, code: failure.code, resetsAt: failure.resetsAt)
            }
        }
    }

    /// A non-200 relay answer, before it becomes a public VeniceE2EEError.
    private struct RelayFailure: Error {
        let status: Int
        let code: String?
        let resetsAt: String?
        let staleKeyModels: [String]
    }

    private func sendOnce(tier: String,
                          chain: [String],
                          messages: [VeniceE2EEMessage],
                          stream: Bool,
                          maxTokens: Int?,
                          temperature: Double?,
                          refreshAuth: Bool) async throws -> AsyncThrowingStream<VeniceE2EEEvent, Error> {
        lastStats.attempts = []
        lastStats.skipped = [:]

        var attempts: [[String: Any]] = []
        var encryptedByKey: [Data: [[String: String]]] = [:]
        for model in chain {
            let key: AttestedModelKey
            do {
                key = try await attestedKey(for: model)
            } catch {
                // Never send to a model we couldn't verify.
                lastStats.skipped[model] = String(describing: error)
                continue
            }
            if encryptedByKey[key.publicKey] == nil {
                encryptedByKey[key.publicKey] = try messages.map {
                    ["role": $0.role.rawValue,
                     "content": try VeniceE2EECrypto.encrypt($0.content, toModelKey: key.publicKey)]
                }
            }
            attempts.append(["model": model, "modelPubKey": key.publicKeyHex,
                             "messages": encryptedByKey[key.publicKey]!])
            lastStats.attempts.append(model)
        }
        guard !attempts.isEmpty else { throw VeniceE2EEError.noAttestableModel(chain) }

        let clientKey = try VeniceClientKey()
        var body: [String: Any] = ["clientPubKey": clientKey.publicKeyHex, "attempts": attempts, "stream": stream]
        if let maxTokens { body["maxTokens"] = maxTokens }
        if let temperature { body["temperature"] = temperature }

        var request = URLRequest(url: url(tier: tier))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if let authorizer {
            let token = try await authorizer.relayToken(refresh: refreshAuth)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw VeniceE2EEError.malformedResponse }
        guard http.statusCode == 200 else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte); if raw.count > 4096 { break } }
            let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            throw RelayFailure(status: http.statusCode,
                               code: json?["code"] as? String,
                               resetsAt: json?["resetsAt"] as? String,
                               staleKeyModels: (json?["staleKeyModels"] as? [String]) ?? [])
        }
        // Served by a fallback after an enclave couldn't decrypt: attest that
        // model again next time.
        if let stale = http.value(forHTTPHeaderField: "x-amach-e2ee-stale-key") {
            for model in stale.split(separator: ",") { cache[model.trimmingCharacters(in: .whitespaces)] = nil }
        }
        let served = VeniceE2EEEvent.served(model: http.value(forHTTPHeaderField: "x-amach-model") ?? "?",
                                            teeProvider: http.value(forHTTPHeaderField: "x-amach-tee-provider"))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(served)
                    if stream {
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { break }
                            guard let chunk = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                            if let usage = chunk["usage"] as? [String: Any] {
                                continuation.yield(.done(promptTokens: usage["prompt_tokens"] as? Int,
                                                         completionTokens: usage["completion_tokens"] as? Int))
                            }
                            let delta = ((chunk["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])
                            if let text = delta?["content"] as? String, !text.isEmpty {
                                continuation.yield(.delta(try self.open(text, with: clientKey)))
                            }
                        }
                    } else {
                        var raw = Data()
                        for try await byte in bytes { raw.append(byte) }
                        guard let json = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
                            throw VeniceE2EEError.malformedResponse
                        }
                        if let text = message["content"] as? String, !text.isEmpty {
                            continuation.yield(.delta(try self.open(text, with: clientKey)))
                        }
                        let usage = json["usage"] as? [String: Any]
                        continuation.yield(.done(promptTokens: usage?["prompt_tokens"] as? Int,
                                                 completionTokens: usage?["completion_tokens"] as? Int))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decrypts one chunk. Fails closed on plaintext: Venice's docs allow it,
    /// but no encrypted request ever produced it, and a plaintext reply means
    /// E2EE wasn't applied (headers dropped, `enable_e2ee` off) or the reply
    /// didn't come from the enclave. Seen 2026-10-23 when Venice ignored
    /// E2EE v2 headers: the model got the ciphertext as text and answered in
    /// the clear.
    private func open(_ text: String, with key: VeniceClientKey) throws -> String {
        guard VeniceE2EECrypto.looksEncrypted(text) else {
            lastStats.plaintextChunks += 1
            throw VeniceE2EEError.plaintextReply
        }
        lastStats.encryptedChunks += 1
        do { return try key.decrypt(text) } catch { throw VeniceE2EEError.decryption }
    }

    private func url(tier: String) -> URL {
        var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "tier", value: tier)]
        return components.url!
    }
}
