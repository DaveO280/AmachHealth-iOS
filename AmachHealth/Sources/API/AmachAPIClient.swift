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
        // Venice AI can take a while with dense health context; keep this higher
        // than the default so we don't fail user-facing chat streaming early.
        config.timeoutIntervalForRequest = 180
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

    /// Store raw Data to Storj (used by Merkle genesis pipeline)
    func storeRawData(
        data: Data,
        path: String,
        encrypt: Bool,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        struct RawDataPayload: Encodable {
            let content: String   // base64-encoded bytes
            let path: String
            let encrypt: Bool
        }
        let payload = RawDataPayload(
            content: data.base64EncodedString(),
            path: path,
            encrypt: encrypt
        )
        let request = StorjRequest(
            action: "storage/store",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: AnyCodable(payload),
            dataType: "merkle-genesis",
            options: StorjStoreOptions(
                metadata: [
                    "path": path,
                    "encrypt": encrypt ? "true" : "false",
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

        let response: StorjResponse<StorjRetrievedData<T>> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Unknown error")
        }

        return result.data
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
                // Skip individual decode/retrieval failures — don't let one bad event kill the whole load
                timelineAPIDebug("Skipping timeline item \(item.uri): \(error.localizedDescription)")
                continue
            }
        }

        timelineAPIDebug("Returning \(events.count) decoded timeline events (skipped \(items.count - events.count))")
        return events.sorted { $0.timestamp > $1.timestamp }
    }

    func listLabRecords(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [StorjListItem] {
        async let bloodworkLegacy = listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: "bloodwork"
        )
        async let dexaLegacy = listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: "dexa"
        )
        async let bloodworkFHIR = listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: "bloodwork-report-fhir"
        )
        async let dexaFHIR = listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: "dexa-report-fhir"
        )

        let allItems = try await (bloodworkLegacy + dexaLegacy + bloodworkFHIR + dexaFHIR)
        let deduped = dedupeLabItems(allItems)
        if !deduped.isEmpty {
            return deduped
        }

        let fallbackItems = try await listHealthData(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey,
            dataType: nil
        )

        return dedupeLabItems(
            fallbackItems.filter { item in
                let normalizedType = item.dataType.lowercased()
                if normalizedType.contains("bloodwork") || normalizedType.contains("dexa") {
                    return true
                }

                let reportType = item.metadata?["reporttype"]?.lowercased()
                    ?? item.metadata?["type"]?.lowercased()
                return reportType == "bloodwork" || reportType == "dexa"
            }
        )
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

    func retrieveBloodworkReport(
        storjUri: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> RemoteBloodworkReport {
        let request = ReportRetrieveRequest(
            action: "report/retrieve",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            storjUri: storjUri,
            reportType: "bloodwork"
        )

        let response: StorjResponse<RemoteBloodworkReport> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Failed to retrieve bloodwork report")
        }

        return result
    }

    func retrieveDexaReport(
        storjUri: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> RemoteDexaReport {
        let request = ReportRetrieveRequest(
            action: "report/retrieve",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            storjUri: storjUri,
            reportType: "dexa"
        )

        let response: StorjResponse<RemoteDexaReport> = try await post(
            path: "/api/storj",
            body: request
        )

        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Failed to retrieve DEXA report")
        }

        return result
    }

    // MARK: - Health Summary API

    /// Get health summary for AI context.
    ///
    /// Converts aggregated `DailySummary` data (keyed by ISO date string) into the
    /// `Record<string, HealthSample[]>` shape the backend expects, then calls
    /// `/api/health/summary` to generate per-metric stats and trend analysis.
    ///
    /// - Parameters:
    ///   - walletAddress: User's wallet address for auth.
    ///   - encryptionKey: Derived encryption key.
    ///   - dailySummaries: Date-keyed map of aggregated daily health data from HealthKit.
    ///   - period: Aggregation window — "week" (≤7 days), "month" (≤31 days), or "month".
    func getHealthSummary(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        dailySummaries: [String: DailySummary],
        period: String = "week"
    ) async throws -> HealthSummary {
        let data = Self.buildHealthSampleData(from: dailySummaries)
        let request = HealthSummaryRequest(
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: data,
            period: period
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

    /// Converts `[date: DailySummary]` to `[metricType: [WebHealthSample]]` for the backend.
    /// Each daily aggregate becomes one `WebHealthSample` per metric type, dated at midnight UTC.
    static func buildHealthSampleData(
        from dailySummaries: [String: DailySummary]
    ) -> [String: [WebHealthSample]] {
        var metricSamples: [String: [WebHealthSample]] = [:]

        let sortedDays = dailySummaries.keys.sorted()
        for dateString in sortedDays {
            guard let daily = dailySummaries[dateString] else { continue }
            let startDate = dateString + "T00:00:00Z"

            // Scalar metrics from the aggregated MetricSummary
            for (metricType, summary) in daily.metrics {
                // Use avg for rate metrics, total for cumulative (steps, calories)
                let value: Double
                let isCumulative = metricType.contains("stepCount")
                    || metricType.contains("EnergyBurned")
                    || metricType.contains("Distance")
                    || metricType.contains("FlightsClimbed")
                if isCumulative {
                    value = summary.total ?? summary.avg ?? 0
                } else {
                    value = summary.avg ?? summary.total ?? 0
                }
                let sample = WebHealthSample(
                    startDate: startDate,
                    value: value,
                    unit: WebHealthSample.unit(for: metricType),
                    type: metricType
                )
                metricSamples[metricType, default: []].append(sample)
            }

            // Sleep — send total sleep minutes as a sleepAnalysis sample
            if let sleep = daily.sleep, sleep.total > 0 {
                let sleepSample = WebHealthSample(
                    startDate: dateString + "T22:00:00Z",
                    value: Double(sleep.total),
                    unit: "min",
                    type: "sleepAnalysis"
                )
                metricSamples["sleepAnalysis", default: []].append(sleepSample)
            }
        }

        return metricSamples
    }

    // MARK: - AI Chat (request/response)

    /// Send a message to Luma via /api/ai/chat (non-streaming).
    /// Use streamLumaChat() for progressive token delivery.
    func sendChatMessage(
        _ message: String,
        history: [AIChatHistoryMessage],
        context: AIChatContext? = nil,
        mode: ChatMode = .quick
    ) async throws -> AIChatResponse {
        let request = AIChatRequest(
            message: message,
            context: context,
            history: history,
            options: AIChatOptions(mode: mode.rawValue)
        )
        let response: AIChatResponse = try await post(path: "/api/ai/chat", body: request)
        #if DEBUG
        print("🤖 [Luma] Response: \(response.content.prefix(120))… (\(response.content.count) chars)")
        if response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let reqBody = try? encoder.encode(request),
               let reqStr = String(data: reqBody, encoding: .utf8) {
                print("🔍 [Luma] EMPTY RESPONSE — dumping request payload:\n\(reqStr.prefix(3000))")
            }
        }
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
        metric: String? = nil,
        mode: ChatMode = .quick
    ) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Use /api/ai/chat which handles system prompt, context
                    // injection, and messages array construction server-side
                    let response = try await self.sendChatMessage(
                        message,
                        history: history,
                        context: context,
                        mode: mode
                    )

                    // Guard: if the AI returned empty content, surface an error
                    // instead of rendering a blank assistant bubble
                    let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else {
                        #if DEBUG
                        print("⚠️ [Luma] AI returned empty content")
                        #endif
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
                    #if DEBUG
                    print("⚠️ [Luma] streamLumaChat error: \(error.localizedDescription)")
                    #endif
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Save distilled conversation memory (facts + summaries) to Storj.
    /// Lightweight payload — typically under 50KB vs 100KB+ for raw chat sessions.
    func storeConversationMemory(
        facts: [CriticalFact],
        summaries: [SessionSummary],
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> String {
        let payload = ConversationMemoryStorjPayload(facts: facts, summaries: summaries)
        let request = StorjRequest(
            action: "storage/store",
            userAddress: walletAddress,
            encryptionKey: encryptionKey,
            data: AnyCodable(payload),
            dataType: "conversation-memory",
            options: StorjStoreOptions(
                metadata: [
                    "factCount": String(facts.count),
                    "summaryCount": String(summaries.count),
                    "platform": "ios"
                ]
            )
        )

        let response: StorjResponse<StorjStoreResult> = try await post(path: "/api/storj", body: request)
        guard response.success, let result = response.result else {
            throw APIError.requestFailed(response.error ?? "Failed to store conversation memory")
        }
        return result.storjUri
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

    // MARK: - Profile

    func readProfile(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> ResolvedProfile? {
        let request = ProfileReadRequest(
            userAddress: walletAddress,
            encryptionKey: encryptionKey
        )

        let response: ProfileReadResponse = try await post(
            path: "/api/profile/read",
            body: request
        )

        guard response.success else {
            throw APIError.requestFailed(response.error ?? "Profile read failed")
        }

        return response.profile
    }

    // MARK: - Health Metric Proofs

    /// Ask the backend to generate a signed, on-chain anchored proof document.
    func generateHealthMetricProof(
        claim: HealthMetricClaim,
        walletAddress: String
    ) async throws -> HealthMetricProofDocument {
        struct ProofRequest: Encodable {
            let claim: HealthMetricClaim
            let walletAddress: String
            let platform: String
        }

        let request = ProofRequest(
            claim: claim,
            walletAddress: walletAddress,
            platform: "ios"
        )

        return try await post(path: "/api/proofs/generate", body: request)
    }

    /// Verify a proof document against on-chain attestations.
    func verifyHealthMetricProof(
        proof: HealthMetricProofDocument
    ) async throws -> HealthMetricProofVerificationResult {
        struct VerifyRequest: Encodable {
            let proof: HealthMetricProofDocument
        }

        return try await post(
            path: "/api/proofs/verify",
            body: VerifyRequest(proof: proof)
        )
    }

    // MARK: - ZK Coverage (Dev)

    func generateGenesisRoot(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        leaves: [MerkleGenesisLeafRequest]
    ) async throws -> MerkleGenesisResponse {
        struct GenesisRequest: Encodable {
            let walletAddress: String
            let leaves: [MerkleGenesisLeafRequest]
            let encryptionKey: WalletEncryptionKey
        }
        return try await post(
            path: "/api/merkle/genesis",
            body: GenesisRequest(
                walletAddress: walletAddress,
                leaves: leaves,
                encryptionKey: encryptionKey
            )
        )
    }

    func generateCoverageProof(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey,
        startDayId: UInt32,
        endDayId: UInt32,
        minDays: UInt32
    ) async throws -> CoverageProofGenerateResponse {
        struct CoverageRequest: Encodable {
            let walletAddress: String
            let startDayId: UInt32
            let endDayId: UInt32
            let minDays: UInt32
            let encryptionKey: WalletEncryptionKey
        }
        return try await post(
            path: "/api/proofs/coverage/generate",
            body: CoverageRequest(
                walletAddress: walletAddress,
                startDayId: startDayId,
                endDayId: endDayId,
                minDays: minDays,
                encryptionKey: encryptionKey
            )
        )
    }

    func verifyCoverageProof(
        proof: CoverageProof
    ) async throws -> CoverageProofVerifyResponse {
        struct VerifyCoverageRequest: Encodable {
            let proof: CoverageProofPayload
            let publicSignals: [String]
        }
        return try await post(
            path: "/api/proofs/coverage/verify",
            body: VerifyCoverageRequest(
                proof: proof.proof,
                publicSignals: proof.publicSignals
            )
        )
    }

    // MARK: - Feedback

    /// Submit a Luma response rating to /api/feedback.
    /// Sends rating + screen + optional user-written comment.
    /// No message content — only what the user explicitly types as feedback.
    /// Fire-and-forget: callers should use try? so a missing endpoint doesn't surface errors.
    func submitChatFeedback(rating: String, screen: String?, comment: String? = nil) async throws {
        struct FeedbackRequest: Encodable {
            let rating: String
            let screen: String?
            let platform: String
            let comment: String?
        }
        struct FeedbackResponse: Decodable {
            let success: Bool?
        }
        let request = FeedbackRequest(rating: rating, screen: screen, platform: "ios", comment: comment)
        _ = try await post(path: "/api/feedback", body: request) as FeedbackResponse
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

        let startTime = Date()
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        #if DEBUG
        print("📡 [API] ← \(httpResponse.statusCode) (\(data.count) bytes)")
        print("📡 [API] duration: \(Int(Date().timeIntervalSince(startTime) * 1000))ms")
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
        do {
            return try decoder.decode(R.self, from: data)
        } catch {
            #if DEBUG
            if let body = String(data: data.prefix(1000), encoding: .utf8) {
                print("📡 [API] Decode error: \(error)")
                print("📡 [API] Response body: \(body)")
            }
            #endif
            throw error
        }
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

    private func dedupeLabItems(_ items: [StorjListItem]) -> [StorjListItem] {
        let uniqueByURI = Dictionary(items.map { ($0.uri, $0) }, uniquingKeysWith: { current, _ in current })
        return uniqueByURI.values.sorted { $0.uploadedAt > $1.uploadedAt }
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

struct ReportRetrieveRequest: Encodable {
    let action: String
    let userAddress: String
    let encryptionKey: WalletEncryptionKey
    let storjUri: String
    let reportType: String
}

struct StorjStoreOptions: Encodable {
    let metadata: [String: String]
}

struct HealthSummaryRequest: Encodable {
    let userAddress: String
    let encryptionKey: WalletEncryptionKey
    let data: [String: [WebHealthSample]]
    let period: String
}

/// A single health measurement sample — matches the web backend's `HealthSample` type.
/// Each metric key in `HealthSummaryRequest.data` maps to an array of these.
struct WebHealthSample: Encodable {
    let startDate: String   // ISO-8601 e.g. "2026-04-01T00:00:00Z"
    let value: Double
    let unit: String
    let type: String

    /// Canonical unit string for a given HealthKit metric type identifier.
    static func unit(for metricType: String) -> String {
        switch metricType {
        case "heartRate", "restingHeartRate", "walkingHeartRateAverage": return "bpm"
        case "heartRateVariability": return "ms"
        case "stepCount": return "count"
        case "activeEnergyBurned", "basalEnergyBurned": return "kcal"
        case "oxygenSaturation", "bodyFatPercentage": return "%"
        case "respiratoryRate": return "breaths/min"
        case "bodyMass": return "kg"
        case "height": return "m"
        case "sleepAnalysis": return "min"
        case "mindfulSession": return "min"
        default: return "units"
        }
    }
}

struct ProfileReadRequest: Encodable {
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

struct StorjRetrievedData<T: Decodable>: Decodable {
    let data: T
    let storjUri: String?
    let contentHash: String?
    let verified: Bool?
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
    let period: String?
    let generatedAt: String?
    let summaries: [MetricSummaryResult]?
    let overallScore: Double?
    let metricsCount: Int?
    let error: String?

    /// Convenience accessor — builds a `HealthSummary` from the flat response fields.
    var summary: HealthSummary? {
        guard success else { return nil }
        return HealthSummary(
            period: period,
            generatedAt: generatedAt,
            summaries: summaries,
            overallScore: overallScore,
            metricsCount: metricsCount ?? 0
        )
    }
}

struct ProfileReadResponse: Decodable {
    let success: Bool
    let profile: ResolvedProfile?
    let metadata: ResolvedProfileMetadata?
    let error: String?
}

struct ResolvedProfile: Decodable {
    let birthDate: String?
    let sex: String?
    let height: Double?
    let weight: Double?
    let source: String?
    let updatedAt: TimeInterval?
    let version: Int?
    let isActive: Bool?
}

struct ResolvedProfileMetadata: Decodable {
    let hasProfile: Bool?
    let isActive: Bool?
    let version: Int?
}

struct RemoteBloodworkReport: Decodable {
    // Backend payload sometimes omits `type`; Luma lab extraction does not rely on it.
    let type: String?
    let source: String?
    let reportDate: String?
    let laboratory: String?
    let metrics: [RemoteBloodworkMetric]
    let notes: [String]?
}

struct RemoteBloodworkMetric: Decodable, Identifiable {
    var id: String { [panel ?? "", name, unit ?? ""].joined(separator: "|") }

    let name: String
    let value: Double?
    let valueText: String?
    let unit: String?
    let referenceRange: String?
    let panel: String?
    let flag: String?
}

struct RemoteDexaReport: Decodable {
    // Backend payload sometimes omits `type`; Luma lab extraction does not rely on it.
    let type: String?
    let source: String?
    let scanDate: String?
    let totalBodyFatPercent: Double?
    let totalLeanMassKg: Double?
    let visceralFatRating: Double?
    let visceralFatAreaCm2: Double?
    let visceralFatVolumeCm3: Double?
    let androidGynoidRatio: Double?
    let boneDensityTotal: RemoteDexaBoneDensity?
    let notes: [String]?
}

struct RemoteDexaBoneDensity: Decodable {
    let bmd: Double?
    let tScore: Double?
    let zScore: Double?
}

struct HealthSummary: Decodable {
    let period: String?
    let generatedAt: String?
    let summaries: [MetricSummaryResult]?
    let overallScore: Double?
    let metricsCount: Int

    // MARK: Convenience helpers

    func average(for metric: String) -> Double? {
        summaries?.first(where: { $0.metric == metric })?.stats?.average
    }

    func trend(for metric: String) -> String? {
        summaries?.first(where: { $0.metric == metric })?.trend
    }
}

struct MetricSummaryResult: Decodable {
    let metric: String
    let period: String?
    let stats: MetricStats?
    let trend: String?
    let unit: String?
}

struct MetricStats: Decodable {
    let average: Double?
    let min: Double?
    let max: Double?
    let latest: Double?
    let count: Int?
    let sum: Double?
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

// MARK: - ZK Coverage Types

struct MerkleGenesisLeafRequest: Codable {
    let dayId: UInt32
    let steps: UInt32
    let activeEnergy: UInt32
    let exerciseMinutes: UInt16
    let hrvAvg: UInt16
    let restingHR: UInt16
    let sleepMinutes: UInt16
    let stepDayCount: UInt8
    let energyDayCount: UInt8
    let exerciseDayCount: UInt8
    let hrvDayCount: UInt8
    let restingHrDayCount: UInt8
    let sleepDayCount: UInt8
    let dataFlags: UInt16
    let timezone: Int16
    let sourceHash: String
}

struct MerkleGenesisResponse: Decodable {
    let root: String
    let rootPadded: String
    let startDayId: UInt32
    let endDayId: UInt32
    let leafCount: Int
    let treeDepth: Int
    let storjPaths: GenesisStorjPaths
    /// Sorted ascending; optional for older API responses.
    let leafDayIds: [UInt32]?
    let leafHashesAsHex: [String]?
    /// Server-built `commitMerkleRootWithLeaves` calldata (Lane A); sign/send as `data`.
    let onChainCommitCalldata: String?
    let merkleCommitKind: String?
    let leavesDigestPreview: String?
    let onChainSkipReason: String?
}

struct GenesisStorjPaths: Decodable {
    let metadata: String
    let tree: String
    let leaves: String
}

/// Solidity/EVM ABI proof format returned by the backend's groth16 endpoint.
/// Accepts both Solidity format (`a`, `b`, `c`) and raw snarkjs format
/// (`pi_a`, `pi_b`, `pi_c`), converting the latter on the fly.
struct CoverageProofPayload: Codable {
    /// G1 point (2 field elements)
    let a: [String]
    /// G2 point (2 × 2 field elements, coordinates already swapped for EVM)
    let b: [[String]]
    /// G1 point (2 field elements)
    let c: [String]

    private enum CodingKeys: String, CodingKey {
        case a, b, c
        case pi_a, pi_b, pi_c
    }

    init(a: [String], b: [[String]], c: [String]) {
        self.a = a
        self.b = b
        self.c = c
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try Solidity format first, fall back to snarkjs format
        if let a = try? container.decode([String].self, forKey: .a) {
            self.a = a
            self.b = try container.decode([[String]].self, forKey: .b)
            self.c = try container.decode([String].self, forKey: .c)
        } else {
            let piA = try container.decode([String].self, forKey: .pi_a)
            let piB = try container.decode([[String]].self, forKey: .pi_b)
            let piC = try container.decode([String].self, forKey: .pi_c)
            // Convert snarkjs → Solidity: trim homogeneous coordinate, swap b indices for EVM
            self.a = Array(piA.prefix(2))
            self.b = [
                [piB[0][1], piB[0][0]],
                [piB[1][1], piB[1][0]]
            ]
            self.c = Array(piC.prefix(2))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(a, forKey: .a)
        try container.encode(b, forKey: .b)
        try container.encode(c, forKey: .c)
    }
}

struct CoverageProof: Codable {
    let proof: CoverageProofPayload
    let publicSignals: [String]
    let proofHash: String
}

struct CoverageProofGenerateResponse: Decodable {
    let proof: CoverageProofPayload
    let publicSignals: [String]
    let proofHash: String
    let verified: Bool

    private enum CodingKeys: String, CodingKey {
        case proof
        case publicSignals
        case proofHash
        case verified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        proof = try container.decode(CoverageProofPayload.self, forKey: .proof)
        publicSignals = try container.decode([String].self, forKey: .publicSignals)
        // Be tolerant of older backend payloads that omitted proofHash/verified.
        proofHash = try container.decodeIfPresent(String.self, forKey: .proofHash) ?? ""
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? true
    }
}

struct CoverageProofVerifyResponse: Decodable {
    let verified: Bool
}

// MARK: - Payload Types

struct AppleHealthStorjPayload: Codable {
    let manifest: AppleHealthManifest
    let dailySummaries: [String: DailySummary]
}

// MARK: - Wallet Encryption Key (matches web app)
//
// Web expects { key, derivedAt, walletAddress } while iOS keeps
// Swift-friendly property names locally and in Keychain.

struct WalletEncryptionKey: Codable {
    let walletAddress: String
    let encryptionKey: String
    let signature: String
    let timestamp: Int

    init(walletAddress: String, encryptionKey: String, signature: String, timestamp: Int) {
        self.walletAddress = walletAddress
        self.encryptionKey = encryptionKey
        self.signature = signature
        self.timestamp = timestamp
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WebCodingKeys.self)
        try container.encode(walletAddress, forKey: .walletAddress)
        try container.encode(encryptionKey, forKey: .key)
        try container.encode(signature, forKey: .signature)
        try container.encode(timestamp, forKey: .derivedAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexCodingKeys.self)
        walletAddress = try container.decode(String.self, forKey: .walletAddress)

        if let key = try? container.decode(String.self, forKey: .key) {
            encryptionKey = key
        } else {
            encryptionKey = try container.decode(String.self, forKey: .encryptionKey)
        }

        signature = (try? container.decode(String.self, forKey: .signature)) ?? ""

        if let derivedAt = try? container.decode(Int.self, forKey: .derivedAt) {
            timestamp = derivedAt
        } else if let legacyTimestamp = try? container.decode(Int.self, forKey: .timestamp) {
            timestamp = legacyTimestamp
        } else {
            timestamp = Int(Date().timeIntervalSince1970 * 1000)
        }
    }

    private enum WebCodingKeys: String, CodingKey {
        case walletAddress
        case key
        case signature
        case derivedAt
    }

    private enum FlexCodingKeys: String, CodingKey {
        case walletAddress
        case key
        case encryptionKey
        case signature
        case derivedAt
        case timestamp
    }
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
