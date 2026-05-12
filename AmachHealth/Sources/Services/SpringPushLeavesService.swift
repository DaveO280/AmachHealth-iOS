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

    /// Decision the auto-trigger makes after checking on-chain state and
    /// existing Storj uploads. Exposed for unit tests so the (state,
    /// registered, hasBaseline, hasFinish) matrix can be exercised
    /// without hitting RPC or HTTP.
    enum AutoSyncAction: Equatable {
        case captureBaseline
        case captureFinish
        case skipNotRegistered
        case skipNotInActiveOrClaiming
        case skipAlreadyCaptured
        case skipFinishWithoutBaseline
    }

    // MARK: - Published state

    @Published private(set) var isUploading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastResult: CaptureResult?
    /// Outcome of the most recent auto-sync attempt. `nil` until the
    /// first attempt resolves; mirrors `lastResult` for whichever capture
    /// the trigger fired. Exists so a future "Spring Push status" UI can
    /// surface what the silent background task did without the service
    /// having to keep a separate UI-state model.
    @Published private(set) var lastAutoSyncAction: AutoSyncAction?

    // MARK: - Dependencies

    private let healthKit: HealthKitService
    private let wallet: WalletService
    private let api: AmachAPIClient
    private let contest: SpringPushContestService

    /// Re-entry guard for the silent auto-sync. Foreground transitions
    /// + wallet-connect + cold-start can all fire close together; this
    /// drops the redundant runs without blocking the explicit
    /// `captureBaseline()` / `captureFinish()` callers.
    private var autoSyncInFlight = false

    private init(
        healthKit: HealthKitService = .shared,
        wallet: WalletService = .shared,
        api: AmachAPIClient = .shared,
        contest: SpringPushContestService = .shared
    ) {
        self.healthKit = healthKit
        self.wallet = wallet
        self.api = api
        self.contest = contest
    }

    // MARK: - Trigger points
    //
    // The Spring Push capture is a fully-silent background task — no UI
    // gates it. `autoSyncIfNeeded()` is the only entry point real callers
    // should hit; the explicit `captureBaseline()` / `captureFinish()`
    // variants stay public for diagnostics and a possible "retry" affordance.

    /// Silent auto-sync. Reads the contest state + the user's
    /// registration via `SpringPushContestService`, decides whether the
    /// baseline or finish leaves need capturing for this wallet right
    /// now, and runs the capture if so. Re-entrant calls (foreground +
    /// wallet-connect within the same window) collapse to a single run.
    ///
    /// This method never throws — failures land in `lastError` and are
    /// printed so the future status UI can show them, but the lifecycle
    /// callers (scene phase, wallet connect, cold start) don't need to
    /// handle errors. Returns the decided action so a caller that wants
    /// telemetry can observe what happened.
    @discardableResult
    func autoSyncIfNeeded() async -> AutoSyncAction? {
        guard !autoSyncInFlight else { return lastAutoSyncAction }
        autoSyncInFlight = true
        defer { autoSyncInFlight = false }

        guard wallet.isConnected,
              let walletAddress = wallet.address,
              let encryptionKey = wallet.encryptionKey else {
            return nil
        }

        let state: ContestState
        let registered: Bool
        do {
            (state, registered) = try await contest.fetchStateAndRegistration(address: walletAddress)
        } catch {
            lastError = error.localizedDescription
            print("🌱 [SpringPush] auto-sync: contest read failed — \(error.localizedDescription)")
            return nil
        }

        // Cheap pre-flight: skip the Storj round-trip when the state +
        // registration already rule out any capture.
        let preFlight = Self.decideAction(
            state: state,
            registered: registered,
            hasBaseline: nil,
            hasFinish: nil
        )
        switch preFlight {
        case .skipNotRegistered, .skipNotInActiveOrClaiming:
            lastAutoSyncAction = preFlight
            return preFlight
        default:
            break
        }

        // Check both bundles in parallel; either being non-empty means
        // a previous capture (manual or auto) already uploaded.
        let baselineExists: Bool
        let finishExists: Bool
        do {
            async let bTask = api.listHealthData(
                walletAddress: walletAddress,
                encryptionKey: encryptionKey,
                dataType: "merkle-v2-baseline-leaves"
            )
            async let fTask = api.listHealthData(
                walletAddress: walletAddress,
                encryptionKey: encryptionKey,
                dataType: "merkle-v2-finish-leaves"
            )
            let (baselineList, finishList) = try await (bTask, fTask)
            baselineExists = !baselineList.isEmpty
            finishExists = !finishList.isEmpty
        } catch {
            lastError = error.localizedDescription
            print("🌱 [SpringPush] auto-sync: Storj list failed — \(error.localizedDescription)")
            return nil
        }

        let action = Self.decideAction(
            state: state,
            registered: registered,
            hasBaseline: baselineExists,
            hasFinish: finishExists
        )
        lastAutoSyncAction = action
        switch action {
        case .captureBaseline:
            do {
                _ = try await captureAndUpload(window: .baseline, daysBack: 90, endDate: Date())
                print("🌱 [SpringPush] auto-sync: baseline captured")
            } catch {
                lastError = error.localizedDescription
                print("🌱 [SpringPush] auto-sync: baseline capture failed — \(error.localizedDescription)")
            }
        case .captureFinish:
            do {
                _ = try await captureAndUpload(window: .finish, daysBack: 90, endDate: Date())
                print("🌱 [SpringPush] auto-sync: finish captured")
            } catch {
                lastError = error.localizedDescription
                print("🌱 [SpringPush] auto-sync: finish capture failed — \(error.localizedDescription)")
            }
        case .skipNotRegistered,
             .skipNotInActiveOrClaiming,
             .skipAlreadyCaptured,
             .skipFinishWithoutBaseline:
            break
        }
        return action
    }

    /// Pure decision function exposed for unit tests. Combines on-chain
    /// state + registration + Storj presence flags into the action the
    /// auto-trigger should take. Pass `nil` for `hasBaseline` /
    /// `hasFinish` when only the pre-flight (state/registration) is
    /// known — the function returns a `skip*` decision in that case
    /// or `nil` (representing "Storj check is needed").
    nonisolated static func decideAction(
        state: ContestState,
        registered: Bool,
        hasBaseline: Bool?,
        hasFinish: Bool?
    ) -> AutoSyncAction {
        guard registered else { return .skipNotRegistered }
        switch state {
        case .active:
            guard let hasBaseline else {
                // Storj not yet checked — caller should fetch.
                return .captureBaseline
            }
            return hasBaseline ? .skipAlreadyCaptured : .captureBaseline
        case .claiming:
            guard let hasBaseline else {
                // Pre-flight: assume we'd capture finish; the post-check
                // pass narrows this to the right outcome.
                return .captureFinish
            }
            guard hasBaseline else {
                // No baseline was ever uploaded — finish on its own is
                // useless to the proof builder. Surface this as a
                // distinct skip so a "missed baseline" surface can
                // tell the user.
                return .skipFinishWithoutBaseline
            }
            if hasFinish == true { return .skipAlreadyCaptured }
            return .captureFinish
        default:
            return .skipNotInActiveOrClaiming
        }
    }

    /// Capture the baseline window and upload it to Storj. Public for
    /// diagnostics / retry; the silent auto-trigger goes through
    /// `autoSyncIfNeeded()` instead so it doesn't fire on already-uploaded
    /// wallets.
    @discardableResult
    func captureBaseline(
        daysBack: Int = 90,
        endDate: Date = Date()
    ) async throws -> CaptureResult {
        try await captureAndUpload(window: .baseline, daysBack: daysBack, endDate: endDate)
    }

    /// Capture the finish window and upload it to Storj. Public for
    /// diagnostics / retry.
    @discardableResult
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
                let value = Self.parseSampleValue(point.value, metricType: metricType)
                let sample = HealthSample(
                    metricType: metricType,
                    value: value,
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

    /// Parse a `HealthDataPoint.value` (always a String) into the numeric
    /// `HealthSample.value`. For sleep samples, the HealthKit service
    /// stringifies the HKCategoryValueSleepAnalysis enum into a stage name
    /// ("core"/"deep"/…) for readability; we reverse that here so the
    /// normalization service can bucket by stage. For everything else the
    /// string is already numeric.
    nonisolated static func parseSampleValue(_ raw: String, metricType: String) -> Double {
        if metricType == "HKCategoryTypeIdentifierSleepAnalysis" {
            switch raw {
            case "inBed":   return Double(SleepStageValue.inBed)
            case "asleep":  return Double(SleepStageValue.asleepUnspecified)
            case "awake":   return Double(SleepStageValue.awake)
            case "core":    return Double(SleepStageValue.core)
            case "deep":    return Double(SleepStageValue.deep)
            case "rem":     return Double(SleepStageValue.rem)
            default:        return Double(raw) ?? 0
            }
        }
        return Double(raw) ?? 0
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
