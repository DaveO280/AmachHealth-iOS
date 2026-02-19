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
            ?? "https://app.amach.health"
        self.baseURL = URL(string: baseURLString)!

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
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
        let request = StorjRetrieveRequest(
            action: "storage/retrieve",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            storjUri: storjUri
        )

        let response: StorjResponse<AppleHealthStorjPayload> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Unknown error")
        }

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

    // MARK: - AI Chat

    /// Send a message to Cosaint via /api/ai/chat
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
        return try await post(path: "/api/ai/chat", body: request)
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

    // MARK: - Private Methods

    private func post<T: Encodable, R: Decodable>(
        path: String,
        body: T
    ) async throws -> R {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AmachHealth-iOS/1.0", forHTTPHeaderField: "User-Agent")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
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

struct AttestationRequest: Encodable {
    let userAddress: String
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
