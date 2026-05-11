// SpringPushLeavesService.swift
// AmachHealth
//
// Captures the user's baseline-window and finish-window v2 daily-summary
// leaves for the Spring Push improvement-proof flow, and uploads them to
// the web backend via `POST /api/merkle/v2/upload`.
//
// What this service does NOT do:
//   - Compute Poseidon hashes (server-side — see helpers.ts in
//     Amach-Website/src/app/api/merkle/v2/upload/).
//   - Build the Merkle tree (server-side, same endpoint).
//   - Generate or submit the ZK proof (web wallet flow only — iOS's role
//     in Spring Push is always data collection + upload, not proving).
//
// Why two windows: the AverageImprovementProof circuit reads both the
// baseline and finish leaf bundles for the wallet and proves that the
// average of the circuit's metric (vo2max by default) improved between
// the two windows. See `improvementWitnessBuilder.ts` in the website
// repo for the full spec.

import Foundation
import HealthKit

@MainActor
final class SpringPushLeavesService: ObservableObject {
    static let shared = SpringPushLeavesService()

    // MARK: - Public types

    struct CaptureResult {
        let window: MerkleV2UploadWindow
        let leafCount: Int
        let storjUri: String
        let contentHash: String
        /// Per-leaf Poseidon4 hashes as decimal strings, in the same order
        /// as the captured leaves. Returned by the server; useful for an
        /// in-app "leaves committed" badge.
        let hashes: [String]
    }

    // MARK: - Published state

    @Published private(set) var isUploading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastResult: CaptureResult?

    // MARK: - Dependencies

    private let healthKit: HealthKitService
    private let wallet: WalletService
    private let api: AmachAPIClient

    private init(
        healthKit: HealthKitService = .shared,
        wallet: WalletService = .shared,
        api: AmachAPIClient = .shared
    ) {
        self.healthKit = healthKit
        self.wallet = wallet
        self.api = api
    }

    // MARK: - Trigger points
    //
    // These two methods are the stable entry points the Spring Push UI
    // will call. They are intentionally simple async functions so the
    // future UI can call them from a "Register" button (baseline) and a
    // contest-state observer (finish) without knowing about HealthKit,
    // wallet, or Storj plumbing.

    /// Capture the baseline window and upload it to Storj.
    ///
    /// TODO: call from Spring Push registration flow.
    /// This should fire exactly once per user, right after they
    /// successfully register for the season (after the wallet
    /// signature). If the upload fails, the registration flow should
    /// surface the error and offer a retry — without baseline leaves on
    /// Storj, the user cannot generate an improvement proof at the end
    /// of the contest.
    ///
    /// - Parameters:
    ///   - daysBack: Window size (default: 90 days). Capped to 128 leaves
    ///     by the depth-7 improvement circuit; older days are dropped.
    ///   - endDate: Window end (default: now). Override for testing.
    func captureBaseline(
        daysBack: Int = 90,
        endDate: Date = Date()
    ) async throws -> CaptureResult {
        try await captureAndUpload(window: .baseline, daysBack: daysBack, endDate: endDate)
    }

    /// Capture the finish window and upload it to Storj.
    ///
    /// TODO: call when the contest enters CLAIMING state.
    /// This should fire when the app's contest-state observer transitions
    /// from ACTIVE → CLAIMING and before the user opens the claim UI.
    /// The web proof builder reads both windows via
    /// `fetchImprovementLeavesForWallet` and rejects with a
    /// user-actionable error if either side is missing.
    ///
    /// - Parameters:
    ///   - daysBack: Window size (default: 90 days). Capped to 128 leaves.
    ///   - endDate: Window end (default: now). Override for testing.
    func captureFinish(
        daysBack: Int = 90,
        endDate: Date = Date()
    ) async throws -> CaptureResult {
        try await captureAndUpload(window: .finish, daysBack: daysBack, endDate: endDate)
    }

    // MARK: - Pipeline

    private func captureAndUpload(
        window: MerkleV2UploadWindow,
        daysBack: Int,
        endDate: Date
    ) async throws -> CaptureResult {
        guard wallet.isConnected,
              let walletAddress = wallet.address,
              let encryptionKey = wallet.encryptionKey else {
            throw SpringPushError.walletNotConnected
        }

        let startDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: endDate)
            ?? endDate.addingTimeInterval(-Double(daysBack) * 86_400)

        let bundle = try await fetchHealthKitBundle(from: startDate, to: endDate)

        // Normalize using the same v1 service the genesis pipeline uses —
        // the v2 wire format is a superset, and v2-only fields are zeroed
        // until the normalization pipeline gains explicit v2 support
        // (see MerkleLeafV2Fields.init(from:walletAddress:)).
        let walletBytes = Self.parseWalletAddress(walletAddress)
        let normalizer = MerkleNormalizationService(walletAddress: walletBytes)
        let normalized = normalizer.normalize(
            samples: bundle.quantities,
            workouts: bundle.workouts,
            restingHRSamples: bundle.restingHR,
            start: startDate,
            end: endDate,
            timezone: .current
        )

        guard !normalized.isEmpty else {
            throw SpringPushError.noHealthData
        }

        // Cap at the depth-7 circuit capacity. The most recent days win
        // because the improvement circuit picks lowest-baseline /
        // highest-finish metric values, and a longer baseline window
        // dilutes both with stale data.
        let capped = normalized.count > Self.maxLeavesPerWindow
            ? Array(normalized.suffix(Self.maxLeavesPerWindow))
            : normalized

        let leaves = capped.map { MerkleLeafV2Fields(from: $0, walletAddress: walletAddress) }

        isUploading = true
        lastError = nil
        defer { isUploading = false }

        do {
            let response = try await api.uploadMerkleV2Leaves(
                walletAddress: walletAddress,
                encryptionKey: encryptionKey,
                window: window,
                leaves: leaves
            )
            let result = CaptureResult(
                window: window,
                leafCount: response.leafCount,
                storjUri: response.storjUri,
                contentHash: response.contentHash,
                hashes: response.hashes
            )
            lastResult = result
            return result
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    // MARK: - HealthKit fetch
    //
    // Mirrors the bundle shape MerkleGenesisService uses, so v1 and v2
    // pipelines stay consistent. Workouts are omitted (HealthKitService
    // doesn't surface typed WorkoutSamples yet — same gap as the genesis
    // path), so per-day workout counts will be 0 until that changes.

    private struct Bundle {
        let quantities: [HealthSample]
        let workouts: [WorkoutSample]
        let restingHR: [HealthSample]
    }

    private func fetchHealthKitBundle(from start: Date, to end: Date) async throws -> Bundle {
        let raw = try await healthKit.fetchAllHealthData(from: start, to: end, onProgress: nil)
        var quantities: [HealthSample] = []
        var restingHR: [HealthSample] = []
        for (metricType, points) in raw {
            for point in points {
                let sample = HealthSample(
                    metricType: metricType,
                    value: Double(point.value) ?? 0,
                    unit: "",
                    startDate: point.startDate,
                    endDate: point.endDate,
                    sourceBundleID: point.source ?? "com.apple.health",
                    device: point.device
                )
                if metricType == "HKQuantityTypeIdentifierRestingHeartRate" {
                    restingHR.append(sample)
                } else {
                    quantities.append(sample)
                }
            }
        }
        return Bundle(quantities: quantities, workouts: [], restingHR: restingHR)
    }

    // MARK: - Constants + helpers

    /// Depth-7 improvement-circuit capacity (`2 ** 7`). Matches
    /// `TREE_SIZE` / `MERKLE_DEPTH` in `improvementWitnessBuilder.ts`.
    static let maxLeavesPerWindow = 128

    /// Right-align an EVM wallet hex string into a 32-byte buffer. For a
    /// 20-byte (40-hex-char) address this produces 12 zero bytes + the 20
    /// wallet bytes. Mirrors the parsing the server performs on the
    /// `wallet` field of each leaf.
    nonisolated static func parseWalletAddress(_ address: String) -> Data {
        let stripped = address.hasPrefix("0x") || address.hasPrefix("0X")
            ? String(address.dropFirst(2))
            : address
        var bytes: [UInt8] = []
        var idx = stripped.startIndex
        while idx < stripped.endIndex {
            let next = stripped.index(idx, offsetBy: 2, limitedBy: stripped.endIndex) ?? stripped.endIndex
            if let b = UInt8(stripped[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        let data = Data(bytes)
        if data.count >= 32 { return data.prefix(32) }
        return Data(repeating: 0, count: 32 - data.count) + data
    }
}

// MARK: - Errors

enum SpringPushError: LocalizedError {
    case walletNotConnected
    case noHealthData

    var errorDescription: String? {
        switch self {
        case .walletNotConnected:
            return "Connect your wallet before capturing Spring Push leaves"
        case .noHealthData:
            return "No HealthKit data found in the selected window"
        }
    }
}
