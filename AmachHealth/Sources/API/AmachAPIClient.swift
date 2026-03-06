// AmachAPIClient.swift
// AmachHealth
//
// API client for communicating with the Amach web backend
// Matches the /api/storj and /api/health routes

import Foundation

// MARK: - API Client

final class AmachAPIClient {
    static let shared = AmachAPIClient()

    private let baseURL: URL
    private let session: URLSession

    private init() {
        // Configure base URL from environment or default
        let baseURLString = ProcessInfo.processInfo.environment["AMACH_API_URL"]
            ?? "https://www.amachhealth.com"
        self.baseURL = URL(string: baseURLString)!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120   // Venice AI can take 60-90s with health context
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Storj Operations

    /// Store health data to Storj (encrypted, via backend)
    func storeHealthData(
        payload: AppleHealthStorjPayload,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        let request = StorjRequest(
            action: "storage/store",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: AnyCodable(payload),
            dataType: "apple-health-full-export",
            options: StorjStoreOptions(
                metadata: [
                    "version": "1",
                    "dateRange": "\(payload.manifest.dateRange.start)_\(payload.manifest.dateRange.end)",
                    "metricsCount": String(payload.manifest.metricsPresent.count),
                    "completenessScore": String(payload.manifest.completeness.score),
                    "tier": payload.manifest.completeness.tier,
                    "platform": "ios"
                ]
            )
        )

        let response: StorjResponse<StorjStoreResult> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Unknown error")
        }

        return result
    }

    /// List stored health data from Storj
    func listHealthData(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        dataType: String? = nil
    ) async throws -> [StorjListItem] {
        let request = StorjListRequest(
            action: "storage/list",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: dataType
        )

        let response: StorjResponse<[StorjListItem]> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Unknown error")
        }

        return result
    }

    /// Retrieve health data from Storj
    func retrieveHealthData(
        storjUri: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> AppleHealthStorjPayload {
        try await retrieveStoredData(
            storjUri: storjUri,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            as: AppleHealthStorjPayload.self
        )
    }

    /// Retrieve and decode any Storj payload type.
    func retrieveStoredData<T: Decodable>(
        storjUri: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        as type: T.Type = T.self
    ) async throws -> T {
        let request = StorjRetrieveRequest(
            action: "storage/retrieve",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            storjUri: storjUri
        )

        let response: StorjResponse<T> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Unknown error")
        }

        return result
    }

    // MARK: - Timeline Operations

    func storeTimelineEvent(
        event: TimelineEvent,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        timelineAPIDebug("Storing timeline event \(event.id) for \(walletAddress)")
        let request = StorjRequest(
            action: "storage/store",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: AnyCodable(event),
            dataType: "timeline-event",
            options: StorjStoreOptions(
                metadata: [
                    "eventType": event.eventType.rawValue,
                    "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
                    "platform": "ios"
                ]
            )
        )

        let response: StorjResponse<StorjStoreResult> = try await post(path: "/api/storj", body: request)
        guard response.success, let result = response.result else {
            timelineAPIDebug("Timeline store failed: \(response.error ?? "unknown error")")
            throw APIError.requestFailed(response.error ?? "Timeline store failed")
        }
        timelineAPIDebug("Timeline store succeeded at \(result.storjUri)")
        return result
    }

    func listTimelineEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [TimelineEvent] {
        timelineAPIDebug("Listing timeline Storj items for \(walletAddress)")
        let items = try await listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: "timeline-event"
        )
        timelineAPIDebug("storage/list returned \(items.count) timeline items")

        var events: [TimelineEvent] = []
        events.reserveCapacity(items.count)

        for item in items.sorted(by: { $0.uploadedAt > $1.uploadedAt }) {
            do {
                timelineAPIDebug("Retrieving timeline item \(item.uri)")
                var event = try await retrieveStoredData(
                    storjUri: item.uri,
                    walletAddress: walletAddress,
                    encryptionKey: encryptionKey,
                    as: TimelineEvent.self
                )
                if event.attestationTxHash == nil {
                    event.attestationTxHash = item.attestationTxHash
                }
                timelineAPIDebug("Decoded timeline event \(event.id) of type \(event.eventType.rawValue)")
                events.append(event)
            } catch {
                timelineAPIDebug("Failed to retrieve/decode timeline item \(item.uri): \(error.localizedDescription)")
                throw error
            }
        }

        timelineAPIDebug("Returning \(events.count) decoded timeline events")
        return events.sorted { $0.timestamp > $1.timestamp }
    }

    func listLabRecords(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [StorjListItem] {
        async let bloodwork = listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: "bloodwork"
        )
        async let dexa = listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: "dexa"
        )

        return try await (bloodwork + dexa).sorted { $0.uploadedAt > $1.uploadedAt }
    }

    func storeLabRecord(
        data: LabRecord,
        dataType: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        let request = StorjRequest(
            action: "storage/store",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: AnyCodable(data),
            dataType: dataType,
            options: StorjStoreOptions(
                metadata: labRecordMetadata(for: data, dataType: dataType)
            )
        )

        let response: StorjResponse<StorjStoreResult> = try await post(path: "/api/storj", body: request)
        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Lab store failed")
        }

        _ = try? await createAttestation(
            storjUri: result.storjUri,
            dataType: dataType,
            action: "store",
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )

        return result
    }

    // MARK: - Health Summary API

    /// Get health summary for AI context
    func getHealthSummary(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> HealthSummary {
        let request = HealthSummaryRequest(
            userAddress: walletAddress,
            encryptionKey: encryptionKey
        )

        let response: HealthSummaryResponse = try await post(
            path: "/api/health/summary",
            body: request
        )

        guard response.success, let summary = response.summary else {
            throw APIError.requestFailed(response.error ?? "No summary available")
        }

        return summary
    }

    // MARK: - AI Chat (request/response)

    /// Send a message to Luma via /api/ai/chat (non-streaming, quick mode).
    /// Use streamLumaChat() for progressive token delivery.
    func sendChatMessage(
        _ message: String,
        history: [AIChatHistoryMessage],
        context: AIChatContext? = nil
    ) async throws -> AIChatResponse {
        let request = AIChatRequest(
            message: message,
            context: context,
            history: history,
            options: AIChatOptions(mode: "quick")
        )
        let response: AIChatResponse = try await post(path: "/api/ai/chat", body: request)
        #if DEBUG
        print("🤖 [Luma] Response: \(response.content.prefix(120))… (\(response.content.count) chars)")
        #endif
        return response
    }

    // MARK: - Luma Streaming Chat (simulated via /api/ai/chat)

    /// Stream a Luma response via /api/ai/chat.
    ///
    /// Returns an AsyncThrowingStream<String, Error> that yields the
    /// response in word-sized chunks for progressive UI rendering.
    /// The backend returns a complete response (not SSE), so we
    /// simulate streaming by splitting the text into words.
    func streamLumaChat(
        _ message: String,
        history: [AIChatHistoryMessage],
        context: AIChatContext? = nil,
        screen: String? = nil,
        metric: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Use /api/ai/chat which handles system prompt, context
                    // injection, and messages array construction server-side
                    let response = try await self.sendChatMessage(
                        message,
                        history: history,
                        context: context
                    )

                    // Guard: if the AI returned empty content, surface an error
                    // instead of rendering a blank assistant bubble
                    let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else {
                        print("⚠️ [Luma] AI returned empty content")
                        continuation.finish(throwing: APIError.requestFailed(
                            "Luma returned an empty response. Please try again."
                        ))
                        return
                    }

                    // Simulate streaming by yielding word-by-word
                    let words = content.split(separator: " ")
                    for (i, word) in words.enumerated() {
                        let chunk = (i == 0 ? "" : " ") + word
                        continuation.yield(String(chunk))
                        try await Task.sleep(nanoseconds: 15_000_000) // 15ms per word
                    }

                    continuation.finish()
                } catch {
                    print("⚠️ [Luma] streamLumaChat error: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Save a chat session to Storj (encrypted)
    func storeChatSession(
        _ session: ChatSession,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> String {
        let request = StorjRequest(
            action: "storage/store",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: AnyCodable(session),
            dataType: "chat-session",
            options: StorjStoreOptions(
                metadata: [
                    "sessionId": session.id.uuidString,
                    "messageCount": String(session.messages.count),
                    "createdAt": ISO8601DateFormatter().string(from: session.createdAt),
                    "platform": "ios"
                ]
            )
        )

        let response: StorjResponse<StorjStoreResult> = try await post(path: "/api/storj", body: request)

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Failed to store chat session")
        }

        return result.storjUri
    }

    // MARK: - Attestation API

    /// Get user's attestations from chain
    func getAttestations(
        walletAddress: String
    ) async throws -> [AttestationInfo] {
        let request = AttestationRequest(
            userAddress: walletAddress
        )

        let response: AttestationResponse = try await post(
            path: "/api/attestations",
            body: request
        )

        return response.attestations
    }

    func createAttestation(
        storjUri: String,
        dataType: String,
        action: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        metadata: [String: String] = [:]
    ) async throws -> AttestationResult {
        let request = CreateAttestationRequest(
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            storjUri: storjUri,
            dataType: dataType,
            action: action,
            metadata: metadata,
            platform: "ios"
        )

        let response: CreateAttestationResponse = try await post(
            path: "/api/attestations",
            body: request
        )

        guard response.success, let result = response.attestation else {
            throw APIError.requestFailed(response.error ?? "Attestation failed")
        }

        return result
    }

    // MARK: - Private Methods

    private func post<T: Encodable, R: Decodable>(
        path: String,
        body: T
    ) async throws -> R {
        // Build URL via string concatenation — appendingPathComponent can
        // add trailing slashes that cause 308 redirects on Next.js
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AmachHealth-iOS/1.0", forHTTPHeaderField: "User-Agent")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)

        #if DEBUG
        print("📡 [API] POST \(url.absoluteString) (\(request.httpBody?.count ?? 0) bytes)")
        #endif

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        #if DEBUG
        print("📡 [API] ← \(httpResponse.statusCode) (\(data.count) bytes)")
        #endif

        guard (200...299).contains(httpResponse.statusCode) else {
            #if DEBUG
            if let preview = String(data: data.prefix(500), encoding: .utf8) {
                print("📡 [API] Error body: \(preview)")
            }
            #endif
            // Try to parse error message
            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw APIError.requestFailed(errorResponse.error)
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(R.self, from: data)
    }

    private func labRecordMetadata(for record: LabRecord, dataType: String) -> [String: String] {
        var metadata: [String: String] = [
            "date": ISO8601DateFormatter().string(from: record.date),
            "platform": "ios",
            "type": dataType
        ]

        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0

        let summaryPairs = record.values
            .sorted { $0.key < $1.key }
            .prefix(2)
            .compactMap { key, value -> String? in
                guard let rendered = formatter.string(from: NSNumber(value: value)) else { return nil }
                let unit = record.units[key].map { " \($0)" } ?? ""
                return "\(key): \(rendered)\(unit)"
            }

        if let first = summaryPairs.first {
            metadata["summary1"] = first
        }
        if summaryPairs.count > 1 {
            metadata["summary2"] = Array(summaryPairs)[1]
        }

        return metadata
    }

    private func timelineAPIDebug(_ message: String) {
        #if DEBUG
        print("📚 [TimelineAPI] \(message)")
        #endif
    }
}

// MARK: - Request Types

struct StorjRequest: Encodable {
    let action: String
    let userAddress: String
    let encryptionKey: WalletEncryptionKey
    let data: AnyCodable
    let dataType: String
    let options: StorjStoreOptions?
}

struct StorjListRequest: Encodable {
    let action: String
    let userAddress: String
    let encryptionKey: WalletEncryptionKey
    let dataType: String?
}

struct StorjRetrieveRequest: Encodable {
    let action: String
    let userAddress: String
    let encryptionKey: WalletEncryptionKey
    let storjUri: String
}

struct StorjStoreOptions: Encodable {
    let metadata: [String: String]
}

struct HealthSummaryRequest: Encodable {
    let userAddress: String
    let encryptionKey: WalletEncryptionKey
}

/// Request body for /api/venice/ streaming endpoint.
struct VeniceChatRequest: Encodable {
    let message: String
    let history: [AIChatHistoryMessage]
    let context: AIChatContext?
    let screen: String?          // current screen name for Luma context
    let metric: String?          // current metric (if on MetricDetailView)
    let stream: Bool
}

/// A single token chunk from the Venice SSE stream.
/// Matches the JSON shape: { "content": "token text" }
struct SSEChunk: Decodable {
    let content: String
}

struct AttestationRequest: Encodable {
    let userAddress: String
}

struct TimelineRequest: Encodable {
    let action: String
    let userAddress: String
    let encryptionKey: WalletEncryptionKey
}

struct CreateAttestationRequest: Encodable {
    let userAddress: String
    let encryptionKey: WalletEncryptionKey
    let storjUri: String
    let dataType: String
    let action: String
    let metadata: [String: String]
    let platform: String
}

// MARK: - Response Types

struct StorjResponse<T: Decodable>: Decodable {
    let success: Bool
    let result: T?
    let error: String?
}

struct StorjStoreResult: Decodable {
    let storjUri: String
    let contentHash: String
    let size: Int?
}

struct TimelineEventCollection: Decodable {
    let events: [TimelineEvent]

    init(events: [TimelineEvent]) {
        self.events = events
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let events = try? singleValue.decode([TimelineEvent].self) {
            self.events = events
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.events =
            (try? container.decode([TimelineEvent].self, forKey: .events))
            ?? (try? container.decode([TimelineEvent].self, forKey: .timeline))
            ?? (try? container.decode([TimelineEvent].self, forKey: .items))
            ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case events
        case timeline
        case items
    }
}

struct StorjListItem: Decodable, Identifiable {
    var id: String { uri }

    let uri: String
    let contentHash: String
    let size: Int
    let uploadedAt: TimeInterval
    let dataType: String
    let metadata: [String: String]?

    var uploadDate: Date {
        Date(timeIntervalSince1970: uploadedAt / 1000)
    }

    var tier: String? {
        metadata?["tier"]
    }

    var metricsCount: Int? {
        if let count = metadata?["metricsCount"] ?? metadata?["metricscount"] {
            return Int(count)
        }
        return nil
    }

    var dateRange: (start: String, end: String)? {
        guard let range = metadata?["dateRange"] ?? metadata?["daterange"] else {
            return nil
        }
        let parts = range.split(separator: "_")
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    var attestationTxHash: String? {
        metadata?["attestationTxHash"]
            ?? metadata?["attestationTxhash"]
            ?? metadata?["txHash"]
            ?? metadata?["txhash"]
    }
}

struct HealthSummaryResponse: Decodable {
    let success: Bool
    let summary: HealthSummary?
    let error: String?
}

struct HealthSummary: Decodable {
    let lastUpdated: Date?
    let metricsCount: Int
    let dateRange: DateRange?
    let dailyAverages: [String: Double]?

    struct DateRange: Decodable {
        let start: String
        let end: String
    }
}

struct AttestationResponse: Decodable {
    let attestations: [AttestationInfo]
}

struct CreateAttestationResponse: Decodable {
    let success: Bool
    let attestation: AttestationResult?
    let error: String?
}

struct AttestationResult: Decodable {
    let txHash: String
    let attestationUID: String?
    let blockNumber: Int?
}

struct AttestationInfo: Decodable, Identifiable {
    var id: String { contentHash }

    let contentHash: String
    let dataType: Int
    let startDate: TimeInterval
    let endDate: TimeInterval
    let completenessScore: Int
    let recordCount: Int
    let coreComplete: Bool
    let timestamp: TimeInterval

    var tier: AttestationTier {
        let score = completenessScore / 100  // Contract stores basis points
        if score >= 80 && coreComplete { return .gold }
        if score >= 60 && coreComplete { return .silver }
        if score >= 40 { return .bronze }
        return .none
    }

    var dataTypeName: String {
        switch dataType {
        case 0: return "DEXA"
        case 1: return "Bloodwork"
        case 2: return "Apple Health"
        case 3: return "CGM"
        default: return "Unknown"
        }
    }
}

struct ErrorResponse: Decodable {
    let error: String
}

// MARK: - Payload Types

struct AppleHealthStorjPayload: Codable {
    let manifest: AppleHealthManifest
    let dailySummaries: [String: DailySummary]
}

// MARK: - Wallet Encryption Key (matches web app)

struct WalletEncryptionKey: Codable {
    let walletAddress: String
    let encryptionKey: String
    let signature: String
    let timestamp: Int
}

// MARK: - API Errors

enum APIError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case requestFailed(String)
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .requestFailed(let message):
            return message
        case .encodingFailed:
            return "Failed to encode request"
        case .decodingFailed:
            return "Failed to decode response"
        }
    }
}

// MARK: - AnyCodable Helper

struct AnyCodable: Encodable {
    private let value: Encodable

    init<T: Encodable>(_ value: T) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}
