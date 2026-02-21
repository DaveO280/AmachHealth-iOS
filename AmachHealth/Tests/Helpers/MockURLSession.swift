// MockURLSession.swift
// AmachHealthTests
//
// URLSession test double for API layer tests.
// Intercepts requests and returns scripted responses without
// hitting the network.
//
// Usage:
//   let mock = MockURLSession()
//   mock.stub(url: "/api/storj", json: ["success": true])
//   let client = AmachAPIClient(session: mock.session)

import Foundation
import XCTest


// ============================================================
// MARK: - STUBBED RESPONSE
// ============================================================

struct StubbedResponse {
    let data: Data
    let statusCode: Int
    let headers: [String: String]

    init(data: Data, statusCode: Int = 200, headers: [String: String] = [:]) {
        self.data       = data
        self.statusCode = statusCode
        self.headers    = headers
    }

    /// Convenience: build from any Encodable value.
    static func json<T: Encodable>(_ value: T, statusCode: Int = 200) throws -> StubbedResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return StubbedResponse(data: try encoder.encode(value), statusCode: statusCode)
    }

    /// Convenience: build from a raw JSON dictionary.
    static func dict(_ dict: [String: Any], statusCode: Int = 200) throws -> StubbedResponse {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return StubbedResponse(data: data, statusCode: statusCode)
    }

    /// Convenience: simulate an HTTP error with an error body.
    static func error(_ message: String, statusCode: Int = 400) throws -> StubbedResponse {
        try dict(["error": message], statusCode: statusCode)
    }

    /// Convenience: simulate an SSE stream.
    /// chunks: array of content token strings; produces proper SSE lines.
    static func sse(tokens: [String]) -> StubbedResponse {
        var body = tokens
            .map { "data: {\"content\":\"\($0)\"}\n\n" }
            .joined()
        body += "data: [DONE]\n\n"
        return StubbedResponse(
            data: body.data(using: .utf8)!,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"]
        )
    }
}


// ============================================================
// MARK: - MOCK URL PROTOCOL
// ============================================================

final class MockURLProtocol: URLProtocol {
    // Shared store: pathSuffix → StubbedResponse
    static var stubs: [String: StubbedResponse] = [:]
    static var capturedRequests: [URLRequest] = []

    static func stub(path: String, response: StubbedResponse) {
        stubs[path] = response
    }

    static func reset() {
        stubs.removeAll()
        capturedRequests.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.capturedRequests.append(request)

        // Match on path suffix (ignore host)
        let path = request.url?.path ?? ""
        guard let stub = MockURLProtocol.stubs.first(where: { path.hasSuffix($0.key) })?.value else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileNotFound))
            return
        }

        var headers = stub.headers
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


// ============================================================
// MARK: - MOCK SESSION FACTORY
// ============================================================

enum MockURLSession {
    /// Returns a URLSession configured to use MockURLProtocol.
    static func make() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }
}


// ============================================================
// MARK: - TEST CASE BASE CLASS
// ============================================================
//
// Inherit from this instead of XCTestCase to get automatic
// stub registration and teardown.

class AmachTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: Assertion helpers

    /// Assert that data round-trips through JSONEncoder → JSONDecoder unchanged.
    func assertRoundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data    = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(T.self, from: data)
        XCTAssertEqual(value, decoded, "Round-trip failed", file: file, line: line)
    }

    /// Assert that the last captured request body decodes to the expected type.
    func assertLastRequestBody<T: Decodable>(as type: T.Type, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        guard let request = MockURLProtocol.capturedRequests.last else {
            XCTFail("No requests captured", file: file, line: line)
            throw URLError(.badURL)
        }
        guard let body = request.httpBody else {
            XCTFail("Request had no body", file: file, line: line)
            throw URLError(.badURL)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: body)
    }
}
