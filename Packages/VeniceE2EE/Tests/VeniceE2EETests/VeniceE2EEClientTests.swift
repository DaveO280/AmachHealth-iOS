import Foundation
import P256K
import XCTest
@testable import VeniceE2EE

/// VeniceE2EEClient against a stubbed relay: auth, stale-key retry, error
/// codes and fail-closed plaintext handling. The stub encrypts replies to the
/// request's client key, so the real decrypt path runs.
final class VeniceE2EEClientTests: XCTestCase {
    private let relay = URL(string: "https://relay.test/api/ai/e2ee")!

    override func tearDown() {
        StubRelay.reset()
        super.tearDown()
    }

    private func client(authorizer: (any VeniceRelayAuthorizing)? = nil,
                        attester: FakeAttester = FakeAttester()) -> VeniceE2EEClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubRelay.self]
        return VeniceE2EEClient(relayURL: relay, verifier: attester, authorizer: authorizer,
                                session: URLSession(configuration: config))
    }

    private func reply(_ client: VeniceE2EEClient) async throws -> String {
        var text = ""
        for try await event in try await client.send(tier: "chat", messages: [.init(role: .user, content: "Hi")]) {
            if case let .delta(t) = event { text += t }
        }
        return text
    }

    func testSendsBearerTokenAndRefreshesOnceAfter401() async throws {
        let auth = FakeAuthorizer()
        StubRelay.posts = [.status(401, ["code": "session_expired"]), .reply(["Hello", " there"])]
        let text = try await reply(client(authorizer: auth))
        XCTAssertEqual(text, "Hello there")
        let calls = await auth.calls
        XCTAssertEqual(calls, [false, true])
        XCTAssertEqual(StubRelay.authHeaders, ["Bearer token-1", "Bearer token-2"])
    }

    func testSecond401Surfaces() async throws {
        StubRelay.posts = [.status(401, ["code": "auth_required"]), .status(401, ["code": "auth_required"])]
        do {
            _ = try await reply(client(authorizer: FakeAuthorizer()))
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(error as? VeniceE2EEError, .relay(status: 401, code: "auth_required"))
        }
    }

    func testStaleKeyReattestsAndRetriesOnce() async throws {
        let attester = FakeAttester()
        let c = client(attester: attester)
        StubRelay.posts = [
            .status(503, ["code": "enclave_busy", "staleKeyModels": ["e2ee-glm-5-3-p"]]),
            .reply(["ok"]),
        ]
        let text = try await reply(c)
        XCTAssertEqual(text, "ok")
        // Attested once for the first try, again after the stale report.
        let glm = await attester.count("e2ee-glm-5-3-p")
        let qwen = await attester.count("e2ee-qwen3-8-27b")
        let stats = await c.lastStats
        XCTAssertEqual(glm, 2)
        XCTAssertEqual(qwen, 1)
        XCTAssertEqual(stats.reattested, ["e2ee-glm-5-3-p"])
    }

    func testStaleKeyTwiceIsEnclaveBusy() async throws {
        let stale: StubRelay.Post = .status(503, ["code": "enclave_busy", "staleKeyModels": ["e2ee-glm-5-3-p"]])
        StubRelay.posts = [stale, stale]
        do {
            _ = try await reply(client())
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? VeniceE2EEError, .relay(status: 503, code: "enclave_busy"))
        }
        XCTAssertEqual(StubRelay.postCount, 2)
    }

    func testStaleHeaderOnSuccessReattestsNextTime() async throws {
        let attester = FakeAttester()
        let c = client(attester: attester)
        StubRelay.posts = [.reply(["a"], staleHeader: "e2ee-glm-5-3-p"), .reply(["b"])]
        _ = try await reply(c)
        _ = try await reply(c)
        let glm = await attester.count("e2ee-glm-5-3-p")
        let qwen = await attester.count("e2ee-qwen3-8-27b")
        XCTAssertEqual(glm, 2)
        XCTAssertEqual(qwen, 1)
    }

    func testCreditExhaustedCarriesResetTime() async throws {
        StubRelay.posts = [.status(503, ["code": "ai_credit_exhausted", "resetsAt": "2026-10-24T00:00:00.000Z"])]
        do {
            _ = try await reply(client())
            XCTFail("expected credit error")
        } catch {
            XCTAssertEqual(error as? VeniceE2EEError,
                           .relay(status: 503, code: "ai_credit_exhausted", resetsAt: "2026-10-24T00:00:00.000Z"))
        }
    }

    func testEveryAttestationFailingSendsNothing() async throws {
        do {
            _ = try await reply(client(attester: FakeAttester(failing: true)))
            XCTFail("expected no attestable model")
        } catch {
            XCTAssertEqual(error as? VeniceE2EEError,
                           .noAttestableModel(["e2ee-glm-5-3-p", "e2ee-qwen3-8-27b", "e2ee-glm-5-3-flash"]))
        }
        XCTAssertEqual(StubRelay.postCount, 0)
    }

    func testPlaintextReplyFailsClosed() async throws {
        StubRelay.posts = [.plaintextReply("Your ferritin is low")]
        do {
            _ = try await reply(client())
            XCTFail("expected plaintextReply")
        } catch {
            XCTAssertEqual(error as? VeniceE2EEError, .plaintextReply)
        }
    }

    func testEncryptsOncePerEnclaveKeyAndNeverSendsPlaintext() async throws {
        StubRelay.posts = [.reply(["x"])]
        _ = try await reply(client())
        let body = try XCTUnwrap(StubRelay.lastBody)
        let attempts = try XCTUnwrap(body["attempts"] as? [[String: Any]])
        XCTAssertEqual(attempts.map { $0["model"] as? String },
                       ["e2ee-glm-5-3-p", "e2ee-qwen3-8-27b", "e2ee-glm-5-3-flash"])
        // Qwen and GLM Flash share the near-ai key, so they share ciphertext.
        XCTAssertEqual(attempts[1]["modelPubKey"] as? String, attempts[2]["modelPubKey"] as? String)
        let raw = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        XCTAssertFalse(raw.contains("Hi\""))
    }
}

// MARK: - Fakes

private actor FakeAuthorizer: VeniceRelayAuthorizing {
    private(set) var calls: [Bool] = []
    func relayToken(refresh: Bool) async throws -> String {
        calls.append(refresh)
        return "token-\(calls.count)"
    }
}

/// Two enclave keys, like phala and near-ai: GLM 5.3 on one, Qwen and GLM
/// Flash on the other.
final actor FakeAttester: VeniceModelAttesting {
    private let failing: Bool
    private var counts: [String: Int] = [:]
    private let phala: Data
    private let nearAI: Data

    init(failing: Bool = false) {
        self.failing = failing
        phala = try! P256K.KeyAgreement.PrivateKey(format: .uncompressed).publicKey.uncompressedRepresentation
        nearAI = try! P256K.KeyAgreement.PrivateKey(format: .uncompressed).publicKey.uncompressedRepresentation
    }

    func count(_ model: String) -> Int { counts[model, default: 0] }

    func attest(model: String, session: URLSession) async throws -> AttestedModelKey {
        counts[model, default: 0] += 1
        if failing { throw VeniceAttestationError.http(502) }
        return AttestedModelKey(model: model, publicKey: model == "e2ee-glm-5-3-p" ? phala : nearAI,
                                signingAddress: "0x", teeProvider: nil, mrTD: "", rtmrs: [], verifiedAt: Date())
    }
}

/// Answers GET with the chat chain and POSTs from `posts`, in order.
final class StubRelay: URLProtocol {
    enum Post {
        case status(Int, [String: Any])
        case reply([String], staleHeader: String? = nil)
        case plaintextReply(String)
    }

    nonisolated(unsafe) static var posts: [Post] = []
    nonisolated(unsafe) static var authHeaders: [String] = []
    nonisolated(unsafe) static var postCount = 0
    nonisolated(unsafe) static var lastBody: [String: Any]?

    static func reset() {
        posts = []
        authHeaders = []
        postCount = 0
        lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard request.httpMethod == "POST" else {
            respond(200, json: ["tier": "chat", "models": ["e2ee-glm-5-3-p", "e2ee-qwen3-8-27b", "e2ee-glm-5-3-flash"]])
            return
        }
        Self.postCount += 1
        Self.authHeaders += [request.value(forHTTPHeaderField: "Authorization")].compactMap { $0 }
        let body = (try? JSONSerialization.jsonObject(with: Self.bodyData(request))) as? [String: Any] ?? [:]
        Self.lastBody = body
        guard !Self.posts.isEmpty else { respond(500, json: [:]); return }
        switch Self.posts.removeFirst() {
        case let .status(code, json):
            respond(code, json: json)
        case let .reply(chunks, stale):
            let clientKey = try! VeniceE2EECrypto.normalizePublicKey(body["clientPubKey"] as! String)
            let lines = chunks.map { chunk -> String in
                let ct = try! VeniceE2EECrypto.encrypt(chunk, toModelKey: clientKey)
                return "data: {\"choices\":[{\"delta\":{\"content\":\"\(ct)\"}}]}\n\n"
            }
            var headers = ["Content-Type": "text/event-stream", "x-amach-model": "e2ee-glm-5-3-p"]
            if let stale { headers["x-amach-e2ee-stale-key"] = stale }
            respond(200, body: Data((lines.joined() + "data: [DONE]\n\n").utf8), headers: headers)
        case let .plaintextReply(text):
            respond(200, body: Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n".utf8),
                    headers: ["Content-Type": "text/event-stream"])
        }
    }

    private func respond(_ status: Int, json: [String: Any]) {
        respond(status, body: try! JSONSerialization.data(withJSONObject: json),
                headers: ["Content-Type": "application/json"])
    }

    private func respond(_ status: Int, body: Data, headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
