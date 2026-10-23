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
    case relay(status: Int, code: String?)
    case decryption
    /// A reply chunk arrived unencrypted; the request wasn't served by E2EE.
    case plaintextReply
    case malformedResponse
}

public actor VeniceE2EEClient {
    public let relayURL: URL
    private let verifier: VeniceAttestationVerifier
    private let session: URLSession
    private let attestationTTL: TimeInterval
    private var cache: [String: AttestedModelKey] = [:]

    /// Diagnostics from the last request (counts only, no content).
    public private(set) var lastStats = Stats()

    public struct Stats: Sendable, Equatable {
        public var attempts: [String] = []
        public var skipped: [String: String] = [:]
        public var encryptedChunks = 0
        public var plaintextChunks = 0
    }

    public init(relayURL: URL,
                verifier: VeniceAttestationVerifier = VeniceAttestationVerifier(),
                session: URLSession = .shared,
                attestationTTL: TimeInterval = 600) {
        self.relayURL = relayURL
        self.verifier = verifier
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
        let key = try await verifier.attest(model: model, session: session)
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
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw VeniceE2EEError.malformedResponse }
        guard http.statusCode == 200 else {
            var raw = Data()
            for try await byte in bytes { raw.append(byte); if raw.count > 4096 { break } }
            let code = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any])?["code"] as? String
            throw VeniceE2EEError.relay(status: http.statusCode, code: code)
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
