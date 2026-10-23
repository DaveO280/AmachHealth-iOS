// LumaPrivateChatTests.swift
// AmachHealthTests
//
// End-to-end-encrypted Luma (LumaPrivateChat.swift): the transport against a
// stubbed relay (real encryption both ways), error mapping to Luma's notes,
// and ChatService on the private path.

import XCTest
import VeniceE2EE
@testable import AmachHealth

@MainActor
final class LumaPrivateChatTests: XCTestCase {
    override func tearDown() {
        PrivateRelayStub.reset()
        super.tearDown()
    }

    private func transport(attester: StubAttester = StubAttester()) -> LumaE2EEChatTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrivateRelayStub.self]
        let client = VeniceE2EEClient(relayURL: URL(string: "https://relay.test/api/ai/e2ee")!,
                                      verifier: attester, authorizer: StubAuthorizer(),
                                      session: URLSession(configuration: config))
        return LumaE2EEChatTransport(client: client, prompts: LumaPromptConfigStore(url: nil))
    }

    private func collect(_ t: LumaE2EEChatTransport, _ input: LumaPromptInput) async throws -> [String] {
        var out: [String] = []
        for try await text in t.stream(input) { out.append(text) }
        return out
    }

    private let input = LumaPromptInput(
        message: "My ferritin is 18 ng/mL. Should I worry?",
        contextBlocks: [ContextBlock(type: "metrics", content: "HRV: 52 ms")],
        history: [AIChatHistoryMessage(role: "user", content: "Hi"),
                  AIChatHistoryMessage(role: "assistant", content: "Hello.")])

    func test_streams_trimmed_reply_and_sends_only_ciphertext() async throws {
        PrivateRelayStub.replies = [.chunks(["\n\n", "\nYour ferritin", " is low."])]
        let chunks = try await collect(transport(), input)
        XCTAssertEqual(chunks.joined(), "Your ferritin is low.")
        XCTAssertEqual(chunks.first, "Your ferritin")

        let body = try XCTUnwrap(PrivateRelayStub.lastBody)
        let raw = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!
        for needle in ["ferritin", "Luma", "HRV", "Hello."] {
            XCTAssertFalse(raw.contains(needle), "plaintext \(needle) in relay body")
        }
        let attempt = try XCTUnwrap((body["attempts"] as? [[String: Any]])?.first)
        // One system message (prompt + block, merged), 2 history, user.
        let roles = (attempt["messages"] as? [[String: String]])?.map { $0["role"] }
        XCTAssertEqual(roles, ["system", "user", "assistant", "user"])
        XCTAssertEqual(PrivateRelayStub.authHeader, "Bearer relay-token")
    }

    func test_whitespace_only_reply_is_an_empty_response() async throws {
        PrivateRelayStub.replies = [.chunks(["\n\n", "  "])]
        do {
            _ = try await collect(transport(), input)
            XCTFail("expected empty response")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Luma returned an empty response"))
        }
    }

    func test_every_attestation_failing_is_enclave_busy_and_sends_nothing() async throws {
        do {
            _ = try await collect(transport(attester: StubAttester(failing: true)), input)
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(ChatService.pauseReply(for: error), ChatService.enclaveBusyReply)
        }
        XCTAssertNil(PrivateRelayStub.lastBody)
    }

    func test_relay_busy_and_credit_map_to_lumas_notes() async throws {
        PrivateRelayStub.replies = [.status(503, ["code": "enclave_busy"])]
        do { _ = try await collect(transport(), input); XCTFail() } catch {
            XCTAssertEqual(ChatService.pauseReply(for: error), ChatService.enclaveBusyReply)
        }
        PrivateRelayStub.replies = [.status(503, ["code": "ai_credit_exhausted", "resetsAt": "2026-10-24T00:00:00.000Z"])]
        do { _ = try await collect(transport(), input); XCTFail() } catch {
            guard case .aiCreditExhausted(let resetsAt) = error as? APIError else { return XCTFail("\(error)") }
            XCTAssertNotNil(resetsAt)
            XCTAssertNotNil(ChatService.pauseReply(for: error))
        }
    }

    func test_plaintext_reply_is_never_shown() async throws {
        PrivateRelayStub.replies = [.plaintext("Your ferritin is low")]
        do {
            let chunks = try await collect(transport(), input)
            XCTFail("plaintext shown: \(chunks)")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("ferritin"))
            XCTAssertNil(ChatService.pauseReply(for: error))
        }
    }

    func test_flag_is_off_by_default() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: LumaPrivateChat.defaultsKey)
        defaults.removeObject(forKey: LumaPrivateChat.defaultsKey)
        defer { defaults.set(saved, forKey: LumaPrivateChat.defaultsKey) }
        XCTAssertFalse(LumaPrivateChat.isEnabled)
    }
}

// MARK: - ChatService on the private path

@MainActor
final class ChatServicePrivateChatTests: XCTestCase {
    private final class FakeTransport: LumaChatTransport, @unchecked Sendable {
        var chunks: [String] = []
        var error: Error?
        var inputs: [LumaPromptInput] = []
        func stream(_ input: LumaPromptInput) -> AsyncThrowingStream<String, Error> {
            inputs.append(input)
            let (chunks, error) = (self.chunks, self.error)
            return AsyncThrowingStream { c in
                chunks.forEach { c.yield($0) }
                c.finish(throwing: error)
            }
        }
    }

    func test_streams_into_the_chat_without_touching_api_ai_chat() async {
        let api = MockAmachAPIClient()
        let fake = FakeTransport()
        fake.chunks = ["Your HRV", " is 52 ms."]
        let sut = ChatService(injectedAPI: api, injectedWallet: MockWalletService(), injectedPrivateChat: fake)

        await sut.sendStreaming("How's my HRV?", context: AIChatContext(contextBlocks: [ContextBlock(type: "metrics", content: "HRV 52")]))

        XCTAssertEqual(sut.currentSession.messages.last?.content, "Your HRV is 52 ms.")
        XCTAssertEqual(api.sendChatMessageCallCount + api.streamLumaChatCallCount, 0)
        XCTAssertEqual(fake.inputs.first?.message, "How's my HRV?")
        XCTAssertEqual(fake.inputs.first?.contextBlocks?.map(\.content).contains("HRV 52"), true)
    }

    func test_enclave_busy_becomes_lumas_note_with_retry() async {
        let fake = FakeTransport()
        fake.error = APIError.enclaveBusy
        let sut = ChatService(injectedAPI: MockAmachAPIClient(), injectedWallet: MockWalletService(), injectedPrivateChat: fake)

        await sut.sendStreaming("Hi", context: AIChatContext())

        XCTAssertEqual(sut.currentSession.messages.last?.content, ChatService.enclaveBusyReply)
        XCTAssertEqual(sut.lastFailedMessage, "Hi")
    }
}

// MARK: - Fakes

private actor StubAuthorizer: VeniceRelayAuthorizing {
    func relayToken(refresh: Bool) async throws -> String { "relay-token" }
}

final actor StubAttester: VeniceModelAttesting {
    private let failing: Bool
    private let key = try! VeniceE2EECrypto.normalizePublicKey(VeniceClientKey().publicKeyHex)
    init(failing: Bool = false) { self.failing = failing }
    func attest(model: String, session: URLSession) async throws -> AttestedModelKey {
        if failing { throw URLError(.badServerResponse) }
        return AttestedModelKey(model: model, publicKey: key, signingAddress: "0x", teeProvider: nil,
                                mrTD: "", rtmrs: [], verifiedAt: Date())
    }
}

/// GET → the chat chain; POST → the next of `replies`, encrypted to the
/// request's client key.
final class PrivateRelayStub: URLProtocol {
    enum Reply {
        case chunks([String])
        case status(Int, [String: Any])
        case plaintext(String)
    }

    nonisolated(unsafe) static var replies: [Reply] = []
    nonisolated(unsafe) static var lastBody: [String: Any]?
    nonisolated(unsafe) static var authHeader: String?

    static func reset() { replies = []; lastBody = nil; authHeader = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard request.httpMethod == "POST" else {
            send(200, try! JSONSerialization.data(withJSONObject: ["models": ["e2ee-glm-5-3-p", "e2ee-qwen3-8-27b"]]))
            return
        }
        let body = (try? JSONSerialization.jsonObject(with: Self.read(request))) as? [String: Any] ?? [:]
        Self.lastBody = body
        Self.authHeader = request.value(forHTTPHeaderField: "Authorization")
        guard !Self.replies.isEmpty else { send(500, Data()); return }
        switch Self.replies.removeFirst() {
        case let .status(code, json):
            send(code, try! JSONSerialization.data(withJSONObject: json))
        case let .chunks(chunks):
            let client = try! VeniceE2EECrypto.normalizePublicKey(body["clientPubKey"] as! String)
            let sse = chunks.map {
                "data: {\"choices\":[{\"delta\":{\"content\":\"\(try! VeniceE2EECrypto.encrypt($0, toModelKey: client))\"}}]}\n\n"
            }.joined() + "data: [DONE]\n\n"
            send(200, Data(sse.utf8), type: "text/event-stream")
        case let .plaintext(text):
            send(200, Data("data: {\"choices\":[{\"delta\":{\"content\":\"\(text)\"}}]}\n\n".utf8), type: "text/event-stream")
        }
    }

    private func send(_ status: Int, _ data: Data, type: String = "application/json") {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
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
