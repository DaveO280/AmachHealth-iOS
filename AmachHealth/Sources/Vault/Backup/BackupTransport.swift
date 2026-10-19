// BackupTransport.swift
// AmachHealth
//
// Moves encrypted backup objects between the phone and the Storj backup
// project. The website only hands out access (/api/backup/credentials);
// uploads and downloads go straight to the Storj S3 gateway on presigned
// URLs. Every byte sent here is already ciphertext, and object names are
// random ids, so neither the website nor Storj learns anything about the
// contents beyond size and timing.

import Foundation

/// Storage for opaque, already-encrypted objects in the user's backup folder.
protocol BackupTransport: AnyObject {
    func put(_ objects: [(id: String, data: Data)]) async throws
    /// Missing objects are left out of the result.
    func get(_ ids: [String]) async throws -> [String: Data]
    func delete(_ ids: [String]) async throws
    func listIds() async throws -> [String]
}

/// Signs the backup access challenge with the wallet (personal_sign).
protocol BackupSigner {
    var address: String { get }
    func sign(_ message: String) async throws -> String
}

@MainActor
struct WalletBackupSigner: BackupSigner {
    let address: String

    init?(wallet: WalletService = .shared) {
        guard wallet.isConnected, let address = wallet.address else { return nil }
        self.address = address
    }

    func sign(_ message: String) async throws -> String {
        try await WalletService.shared.signMessage(message)
    }
}

// MARK: - Credentials (website)

/// Talks to /api/backup/credentials. Never sends the encryption key or the
/// key-derivation signature; the challenge it signs is a different message.
final class BackupCredentialsClient {
    struct Session {
        let token: String
        let expiresAt: Date
    }

    enum Op: Encodable {
        case put(String), get(String), delete(String), list(cursor: String?)

        private enum K: String, CodingKey { case op, id, cursor }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            switch self {
            case .put(let id): try c.encode("put", forKey: .op); try c.encode(id, forKey: .id)
            case .get(let id): try c.encode("get", forKey: .op); try c.encode(id, forKey: .id)
            case .delete(let id): try c.encode("delete", forKey: .op); try c.encode(id, forKey: .id)
            case .list(let cursor):
                try c.encode("list", forKey: .op)
                try c.encodeIfPresent(cursor, forKey: .cursor)
            }
        }
    }

    struct PresignedURL: Decodable {
        let op: String
        let id: String?
        let url: URL
    }

    static let maxOpsPerRequest = 200

    private let api: AmachAPIClient
    private let signer: BackupSigner
    private var session: Session?

    init(signer: BackupSigner, api: AmachAPIClient = .shared) {
        self.signer = signer
        self.api = api
    }

    var walletAddress: String { signer.address }

    /// A session token with at least ten minutes left, signing a new
    /// challenge when needed.
    func currentToken() async throws -> String {
        if let session, session.expiresAt.timeIntervalSinceNow > 600 { return session.token }
        struct ChallengeRequest: Encodable { let action = "challenge"; let address: String }
        struct ChallengeResponse: Decodable { let message: String; let challenge: String }
        struct SessionRequest: Encodable {
            let action = "session"
            let address: String
            let challenge: String
            let signature: String
        }
        struct SessionResponse: Decodable { let token: String; let expiresAt: Int64; let mode: String }

        let challenge: ChallengeResponse = try await api.post(
            path: "/api/backup/credentials", body: ChallengeRequest(address: signer.address)
        )
        // Refuse anything that isn't the backup challenge, so this path can
        // never be used to obtain the key-derivation signature.
        guard challenge.message.hasPrefix("Amach backup access\n") else {
            throw BackupError.malformed("unexpected challenge")
        }
        let signature = try await signer.sign(challenge.message)
        let response: SessionResponse = try await api.post(
            path: "/api/backup/credentials",
            body: SessionRequest(address: signer.address, challenge: challenge.challenge, signature: signature)
        )
        let new = Session(token: response.token, expiresAt: Date(unixMillis: response.expiresAt))
        session = new
        return new.token
    }

    /// Token for storage/delete-raw (legacy cleanup).
    func tokenForLegacyDelete() async throws -> String { try await currentToken() }

    func presign(_ ops: [Op]) async throws -> [PresignedURL] {
        struct Request: Encodable { let action = "presign"; let token: String; let ops: [Op] }
        struct Response: Decodable { let urls: [PresignedURL] }
        var out: [PresignedURL] = []
        var start = 0
        var renewed = false
        while start < ops.count {
            let batch = Array(ops[start..<min(start + Self.maxOpsPerRequest, ops.count)])
            let token = try await currentToken()
            do {
                let response: Response = try await api.post(
                    path: "/api/backup/credentials", body: Request(token: token, ops: batch)
                )
                out += response.urls
            } catch APIError.httpError(statusCode: 401), APIError.requestFailed("Session expired") {
                // The server restarted with a new secret or the clock moved:
                // sign one fresh challenge, then give up.
                guard !renewed else { throw BackupError.malformed("backup session refused") }
                renewed = true
                session = nil
                continue
            }
            start += batch.count
        }
        return out
    }
}

// MARK: - Presigned Storj transport

final class PresignedStorjTransport: BackupTransport {
    private let credentials: BackupCredentialsClient
    private let session: URLSession
    private let concurrency = 4

    init(credentials: BackupCredentialsClient) {
        self.credentials = credentials
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    enum TransportError: LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let op): return "Backup storage returned \(code) for \(op)"
            }
        }
    }

    func put(_ objects: [(id: String, data: Data)]) async throws {
        guard !objects.isEmpty else { return }
        let urls = try await credentials.presign(objects.map { .put($0.id) })
        let byId = Dictionary(urls.compactMap { u in u.id.map { ($0, u.url) } }, uniquingKeysWith: { a, _ in a })
        try await forEachConcurrently(objects) { object in
            guard let url = byId[object.id] else { throw BackupError.missingObject(object.id) }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await self.session.upload(for: request, from: object.data)
            try Self.check(response, op: "upload")
        }
    }

    func get(_ ids: [String]) async throws -> [String: Data] {
        guard !ids.isEmpty else { return [:] }
        let urls = try await credentials.presign(ids.map { .get($0) })
        let results = ResultBox()
        try await forEachConcurrently(urls) { item in
            guard let id = item.id else { return }
            let (data, response) = try await self.session.data(from: item.url)
            if (response as? HTTPURLResponse)?.statusCode == 404 { return }
            try Self.check(response, op: "download")
            await results.set(id, data)
        }
        return await results.values
    }

    func delete(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let urls = try await credentials.presign(ids.map { .delete($0) })
        try await forEachConcurrently(urls) { item in
            var request = URLRequest(url: item.url)
            request.httpMethod = "DELETE"
            let (_, response) = try await self.session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404 { return }
            try Self.check(response, op: "delete")
        }
    }

    func listIds() async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        repeat {
            guard let url = try await credentials.presign([.list(cursor: cursor)]).first?.url else { break }
            let (data, response) = try await session.data(from: url)
            try Self.check(response, op: "list")
            let page = ListBucketResultParser.parse(data)
            ids += page.keys.compactMap { key in
                // Keys are "<prefix><id>"; keep only well-formed ids.
                let id = String(key.split(separator: "/").last ?? "")
                return id.count == 32 && id.allSatisfy(\.isHexDigit) ? id : nil
            }
            cursor = page.isTruncated ? page.nextToken : nil
        } while cursor != nil
        return ids
    }

    private static func check(_ response: URLResponse, op: String) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw TransportError.http(http.statusCode, op) }
    }

    private func forEachConcurrently<T>(_ items: [T], _ body: @escaping (T) async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = items.makeIterator()
            for _ in 0..<concurrency {
                guard let item = iterator.next() else { break }
                group.addTask { try await body(item) }
            }
            while try await group.next() != nil {
                try Task.checkCancellation()
                if let item = iterator.next() { group.addTask { try await body(item) } }
            }
        }
    }

    private actor ResultBox {
        var values: [String: Data] = [:]
        func set(_ id: String, _ data: Data) { values[id] = data }
    }
}

/// Minimal ListObjectsV2 XML reader: keys, IsTruncated, NextContinuationToken.
final class ListBucketResultParser: NSObject, XMLParserDelegate {
    struct Page { var keys: [String] = []; var isTruncated = false; var nextToken: String? }

    private var page = Page()
    private var text = ""

    static func parse(_ data: Data) -> Page {
        let delegate = ListBucketResultParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.page
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key": page.keys.append(value)
        case "IsTruncated": page.isTruncated = value == "true"
        case "NextContinuationToken": page.nextToken = value
        default: break
        }
    }
}

// MARK: - In-memory transport (tests, previews)

final class InMemoryBackupTransport: BackupTransport {
    private(set) var objects: [String: Data] = [:]
    private(set) var putCount = 0
    var failPutsAfter: Int?

    func put(_ objects: [(id: String, data: Data)]) async throws {
        for object in objects {
            if let limit = failPutsAfter, putCount >= limit { throw URLError(.networkConnectionLost) }
            self.objects[object.id] = object.data
            putCount += 1
        }
    }

    func get(_ ids: [String]) async throws -> [String: Data] {
        var out: [String: Data] = [:]
        for id in ids { out[id] = objects[id] }
        return out
    }

    func delete(_ ids: [String]) async throws {
        for id in ids { objects.removeValue(forKey: id) }
    }

    func listIds() async throws -> [String] { Array(objects.keys) }
}
