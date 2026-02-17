// HealthDataSyncService.swift
// AmachHealth
//
// Orchestrates the full health data sync flow:
// HealthKit -> Aggregation -> Storj Upload -> On-chain Attestation

import Foundation
import Combine

// MARK: - Sync Service

@MainActor
final class HealthDataSyncService: ObservableObject {
    static let shared = HealthDataSyncService()

    private let healthKit = HealthKitService.shared
    private let wallet = WalletService.shared
    private let api = AmachAPIClient.shared

    @Published var syncState: SyncState = .idle
    @Published var lastSyncDate: Date?
    @Published var lastSyncResult: SyncResult?

    // Stored data for retry
    private var pendingPayload: AppleHealthStorjPayload?

    private init() {
        // Load last sync date from UserDefaults
        if let timestamp = UserDefaults.standard.object(forKey: "lastHealthSyncDate") as? TimeInterval {
            lastSyncDate = Date(timeIntervalSince1970: timestamp)
        }
    }

    // MARK: - Full Sync Flow

    /// Perform a full health data sync to Storj
    func performFullSync(
        from startDate: Date? = nil,
        to endDate: Date = Date()
    ) async {
        // Default to 1 year of data if no start date
        let start = startDate ?? Calendar.current.date(byAdding: .year, value: -1, to: endDate)!

        syncState = .syncing(progress: 0, message: "Starting sync...")

        do {
            // Step 1: Check wallet connection
            guard wallet.isConnected, let encryptionKey = wallet.encryptionKey else {
                throw SyncError.walletNotConnected
            }

            // Step 2: Fetch health data from HealthKit
            syncState = .syncing(progress: 0.1, message: "Fetching health data...")

            let rawData = try await healthKit.fetchAllHealthData(
                from: start,
                to: endDate
            ) { [weak self] progress, message in
                let scaledProgress = 0.1 + (progress * 0.3)  // 10-40%
                self?.syncState = .syncing(progress: scaledProgress, message: message)
            }

            guard !rawData.isEmpty else {
                throw SyncError.noDataAvailable
            }

            // Step 3: Build daily summaries
            syncState = .syncing(progress: 0.45, message: "Aggregating daily summaries...")
            let dailySummaries = healthKit.buildDailySummaries(from: rawData)

            // Step 4: Calculate completeness
            syncState = .syncing(progress: 0.5, message: "Calculating completeness...")
            let metricsPresent = Array(rawData.keys)
            let completeness = healthKit.calculateCompleteness(
                metricsPresent: metricsPresent,
                startDate: start,
                endDate: endDate
            )

            // Step 5: Build manifest
            let manifest = buildManifest(
                metricsPresent: metricsPresent,
                dailySummaries: dailySummaries,
                startDate: start,
                endDate: endDate,
                completeness: completeness,
                rawData: rawData
            )

            // Step 6: Create payload
            let payload = AppleHealthStorjPayload(
                manifest: manifest,
                dailySummaries: dailySummaries
            )

            // Store for potential retry
            self.pendingPayload = payload

            // Step 7: Upload to Storj
            syncState = .syncing(progress: 0.6, message: "Encrypting and uploading to Storj...")

            let storeResult = try await api.storeHealthData(
                payload: payload,
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey
            )

            // Step 8: Record attestation (happens on backend)
            syncState = .syncing(progress: 0.9, message: "Creating on-chain attestation...")

            // The web app handles attestation after Storj save
            // For iOS, we could call a separate attestation endpoint or let web handle it

            // Step 9: Complete!
            syncState = .syncing(progress: 1.0, message: "Sync complete!")

            let result = SyncResult(
                success: true,
                storjUri: storeResult.storjUri,
                contentHash: storeResult.contentHash,
                tier: manifest.completeness.tier,
                score: manifest.completeness.score,
                metricsCount: metricsPresent.count,
                daysCovered: completeness.daysCovered,
                error: nil
            )

            // Save sync date
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate!.timeIntervalSince1970, forKey: "lastHealthSyncDate")

            lastSyncResult = result
            pendingPayload = nil

            // Delay before setting idle to show completion
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            syncState = .idle

        } catch {
            let result = SyncResult(
                success: false,
                storjUri: nil,
                contentHash: nil,
                tier: nil,
                score: nil,
                metricsCount: nil,
                daysCovered: nil,
                error: error.localizedDescription
            )

            lastSyncResult = result
            syncState = .error(error.localizedDescription)
        }
    }

    /// Retry last failed sync
    func retrySync() async {
        guard let payload = pendingPayload,
              let encryptionKey = wallet.encryptionKey else {
            syncState = .error("No pending sync to retry")
            return
        }

        syncState = .syncing(progress: 0.6, message: "Retrying upload...")

        do {
            let storeResult = try await api.storeHealthData(
                payload: payload,
                walletAddress: encryptionKey.walletAddress,
                encryptionKey: encryptionKey
            )

            let result = SyncResult(
                success: true,
                storjUri: storeResult.storjUri,
                contentHash: storeResult.contentHash,
                tier: payload.manifest.completeness.tier,
                score: payload.manifest.completeness.score,
                metricsCount: payload.manifest.metricsPresent.count,
                daysCovered: payload.manifest.completeness.daysCovered,
                error: nil
            )

            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate!.timeIntervalSince1970, forKey: "lastHealthSyncDate")

            lastSyncResult = result
            pendingPayload = nil
            syncState = .idle

        } catch {
            syncState = .error(error.localizedDescription)
        }
    }

    // MARK: - Background Sync

    /// Schedule background sync (called by iOS background task)
    func performBackgroundSync() async -> Bool {
        // Only sync if:
        // 1. Wallet is connected
        // 2. Last sync was more than 24 hours ago

        guard wallet.isConnected,
              wallet.encryptionKey != nil else {
            return false
        }

        if let lastSync = lastSyncDate,
           Date().timeIntervalSince(lastSync) < 86400 {
            return true  // Already synced recently
        }

        // Sync last 7 days for background refresh
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -7, to: endDate)!

        await performFullSync(from: startDate, to: endDate)

        return lastSyncResult?.success ?? false
    }

    // MARK: - Private Methods

    private func buildManifest(
        metricsPresent: [String],
        dailySummaries: [String: DailySummary],
        startDate: Date,
        endDate: Date,
        completeness: (score: Int, tier: AttestationTier, coreComplete: Bool, daysCovered: Int),
        rawData: [String: [HealthDataPoint]]
    ) -> AppleHealthManifest {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Count sources
        var watchCount = 0
        var phoneCount = 0
        var otherCount = 0
        var totalRecords = 0

        for points in rawData.values {
            for point in points {
                totalRecords += 1
                let source = (point.source ?? point.device ?? "").lowercased()

                if source.contains("watch") {
                    watchCount += 1
                } else if source.contains("iphone") || source.contains("phone") {
                    phoneCount += 1
                } else {
                    otherCount += 1
                }
            }
        }

        let total = max(1, watchCount + phoneCount + otherCount)

        return AppleHealthManifest(
            version: 1,
            exportDate: dateFormatter.string(from: Date()),
            uploadDate: ISO8601DateFormatter().string(from: Date()),
            dateRange: AppleHealthManifest.DateRange(
                start: dateFormatter.string(from: startDate),
                end: dateFormatter.string(from: endDate)
            ),
            metricsPresent: metricsPresent.map { normalizeMetricKey($0) },
            completeness: AppleHealthManifest.CompletenessInfo(
                score: completeness.score,
                tier: completeness.tier.rawValue,
                coreComplete: completeness.coreComplete,
                daysCovered: completeness.daysCovered,
                recordCount: totalRecords
            ),
            sources: AppleHealthManifest.SourceInfo(
                watch: (watchCount * 100) / total,
                phone: (phoneCount * 100) / total,
                other: (otherCount * 100) / total
            )
        )
    }

    private func normalizeMetricKey(_ metricType: String) -> String {
        metricType
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutTypeIdentifier", with: "workout")
    }
}

// MARK: - Sync State

enum SyncState: Equatable {
    case idle
    case syncing(progress: Double, message: String)
    case error(String)

    var isLoading: Bool {
        if case .syncing = self { return true }
        return false
    }

    var progress: Double {
        if case .syncing(let progress, _) = self { return progress }
        return 0
    }

    var message: String? {
        switch self {
        case .syncing(_, let message): return message
        case .error(let error): return error
        default: return nil
        }
    }
}

// MARK: - Sync Result

struct SyncResult: Equatable {
    let success: Bool
    let storjUri: String?
    let contentHash: String?
    let tier: String?
    let score: Int?
    let metricsCount: Int?
    let daysCovered: Int?
    let error: String?
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case walletNotConnected
    case noDataAvailable
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .walletNotConnected:
            return "Please connect your wallet to sync health data"
        case .noDataAvailable:
            return "No health data available to sync"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        }
    }
}
