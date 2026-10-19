// MerkleGenesisService.swift
// AmachHealth
//
// Xcode: keep this file OUT of the iOS app target. Run the pipeline on Mac/CI; circom
// proving stays off-device. In-repo for shared tooling and future macOS/CLI targets.
//
// Orchestrates the full genesis Merkle root pipeline.
// This is the Phase 6 integration layer.
//
// Pipeline:
//   HealthKit
//     ↓
//   MerkleNormalizationService    (Phase 1: normalize 90 days → NormalizedDailyLeaf[])
//     ↓
//   LeafHashingService            (Phase 2: Poseidon hash each leaf → HashedLeaf[])
//     ↓
//   MerkleTreeBuilder             (Phase 3: build binary tree → MerkleTreeResult)
//     ↓
//   Storj upload (encrypted tree.json + leaves.json + metadata.json)
//     ↓
//   ZKSyncAttestationService      (Phase 5: commitGenesisRoot() on-chain)
//     ↓
//   [Genesis root confirmed on-chain]
//
// Usage:
//   let result = try await MerkleGenesisService.shared.generateGenesisRoot()

import Foundation
import HealthKit

// MARK: - Pipeline Result

struct GenesisRootResult {
    let root: String                    // Poseidon hash hex (no 0x)
    let rootPadded: String              // 0x-prefixed 32-byte hex for contract
    let leafCount: Int
    let treeDepth: Int
    let startDayId: UInt32
    let endDayId: UInt32
    let storjTreeUri: String?           // storj://... for tree.json.enc
    let storjLeavesUri: String?         // storj://... for leaves.json.enc
    let onChainTxHash: String?          // transaction hash from commitGenesisRoot()
    let generatedAt: Date
}

// MARK: - Pipeline Progress

enum GenesisProgress: Equatable {
    case idle
    case normalizing(progress: Double)  // 0-25%
    case hashing(progress: Double)      // 25-50%
    case buildingTree(progress: Double) // 50-65%
    case uploadingToStorj               // 65-85%
    case submittingOnChain              // 85-95%
    case complete
    case error(String)

    var progressFraction: Double {
        switch self {
        case .idle: return 0
        case .normalizing(let p): return p * 0.25
        case .hashing(let p): return 0.25 + p * 0.25
        case .buildingTree(let p): return 0.50 + p * 0.15
        case .uploadingToStorj: return 0.75
        case .submittingOnChain: return 0.90
        case .complete: return 1.0
        case .error: return 0
        }
    }

    var message: String {
        switch self {
        case .idle: return "Ready"
        case .normalizing: return "Normalizing 90 days of health data…"
        case .hashing: return "Computing Poseidon leaf hashes…"
        case .buildingTree: return "Building Merkle tree…"
        case .uploadingToStorj: return "Encrypting and uploading to Storj…"
        case .submittingOnChain: return "Committing root on-chain…"
        case .complete: return "Genesis root committed ✓"
        case .error(let msg): return "Error: \(msg)"
        }
    }
}

// MARK: - Service

@MainActor
final class MerkleGenesisService: ObservableObject {
    static let shared = MerkleGenesisService()

    @Published private(set) var progress: GenesisProgress = .idle
    @Published private(set) var lastResult: GenesisRootResult?

    private let healthKit = HealthKitService.shared
    private let wallet = WalletService.shared
    private let api = AmachAPIClient.shared
    private let normalization: MerkleNormalizationService
    private let attestation = ZKSyncAttestationService.shared

    private init() {
        // Wallet address not available until connected — initialize with placeholder
        // and reinitialize when wallet connects
        self.normalization = MerkleNormalizationService(walletAddress: Data(repeating: 0, count: 32))
    }

    // MARK: - Main Entry Point

    /// Execute the full genesis root pipeline.
    ///
    /// - Parameters:
    ///   - daysBack: Number of days to include (default: 90)
    ///   - endDate: End of the window (default: today)
    /// - Returns: GenesisRootResult with on-chain confirmation
    func generateGenesisRoot(
        daysBack: Int = 90,
        endDate: Date = Date()
    ) async throws -> GenesisRootResult {
        // The server pipeline (/api/merkle/genesis) needed the encryption key.
        // Off until Phase 6 builds the leaves and tree on the phone.
        progress = .error(GenesisError.serverFlowsDisabled.localizedDescription)
        throw GenesisError.serverFlowsDisabled
    }

    // MARK: - HealthKit Fetching

    private struct HealthKitBundle {
        let quantities: [HealthSample]
        let workouts: [WorkoutSample]
        let restingHR: [HealthSample]
    }

    private func fetchHealthKitSamples(from start: Date, to end: Date) async throws -> HealthKitBundle {
        // We reuse the existing HealthKitService for sample fetching.
        // The raw data it returns must be adapted to our HealthSample type.

        let rawData = try await healthKit.fetchAllHealthData(
            from: start,
            to: end
        ) { [weak self] prog, _ in
            self?.progress = .normalizing(progress: 0.1 + prog * 0.35)
        }

        // Convert HealthDataPoint → HealthSample
        var quantities: [HealthSample] = []
        var restingHR: [HealthSample] = []

        for (metricType, points) in rawData {
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

        // Workouts — HealthKitService doesn't expose typed WorkoutSample objects;
        // pass empty array so normalization runs without workout detail.
        let workouts: [WorkoutSample] = []

        return HealthKitBundle(quantities: quantities, workouts: workouts, restingHR: restingHR)
    }

    // MARK: - On-Chain Submission

    private func submitGenesisRootOnChain(
        treeResult: MerkleTreeResult,
        walletAddress: String,
        remote: MerkleGenesisResponse
    ) async throws -> String? {
        if let calldata = remote.onChainCommitCalldata, !calldata.isEmpty {
            let result = try await attestation.commitMerkleCommitment(calldata: calldata)
            return result.txHash
        }

        if remote.merkleCommitKind == "skip" {
            let reason = remote.onChainSkipReason ?? ""
            if reason.contains("chain read failed") {
                #if DEBUG
                print("⚠️ [Genesis] Lane A calldata unavailable (\(reason)) — trying legacy commit")
                #endif
            } else {
                #if DEBUG
                print("⛓️ [Genesis] On-chain skipped: \(reason.isEmpty ? "no tx needed" : reason)")
                #endif
                return nil
            }
        }

        if let alreadyCommitted = try? await attestation.hasGenesisRoot(address: walletAddress),
           alreadyCommitted {
            #if DEBUG
            print("⛓️ [Genesis] Root already committed for \(walletAddress) — skipping")
            #endif
            return nil
        }

        let genesisInput = ZKSyncAttestationService.GenesisRootInput(
            root:       treeResult.rootPadded,
            startDayId: treeResult.startDayId,
            endDayId:   treeResult.endDayId,
            leafCount:  UInt32(treeResult.leafCount),
            rootType:   0,   // genesis
            syncType:   0    // live sync
        )

        let result = try await attestation.commitGenesisRoot(genesisInput)
        return result.txHash
    }

    // MARK: - Helpers

    private func parseWalletAddress(_ address: String) -> Data {
        // EVM address: "0x" + 20 bytes = 42 chars
        // Left-pad to 32 bytes for MerkleLeaf wallet field
        let stripped = address.hasPrefix("0x") ? String(address.dropFirst(2)) : address
        guard let bytes = Data(hexString: stripped) else {
            return Data(repeating: 0, count: 32)
        }

        if bytes.count < 32 {
            return Data(repeating: 0, count: 32 - bytes.count) + bytes
        }
        return bytes.prefix(32)
    }
}

// MARK: - Errors

enum GenesisError: LocalizedError {
    case walletNotConnected
    case noHealthData
    case hashingFailed(String)
    case treeBuildFailed(String)
    case storjUploadFailed(String)
    case attestationFailed(String)
    case serverFlowsDisabled

    var errorDescription: String? {
        switch self {
        case .serverFlowsDisabled:
            return "Genesis roots are being rebuilt to run on your phone and are off for now."
        case .walletNotConnected:
            return "Connect your wallet before generating the genesis root"
        case .noHealthData:
            return "No health data found in the selected date range"
        case .hashingFailed(let msg):
            return "Leaf hashing failed: \(msg)"
        case .treeBuildFailed(let msg):
            return "Tree construction failed: \(msg)"
        case .storjUploadFailed(let msg):
            return "Storj upload failed: \(msg)"
        case .attestationFailed(let msg):
            return "On-chain commitment failed: \(msg)"
        }
    }
}

// MARK: - Data Hex Extension

private extension Data {
    init?(hexString: String) {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self.init(bytes)
    }

    func hexString() -> String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}

private extension String {
    func padLeft(toLength length: Int, with char: Character) -> String {
        if count >= length { return String(suffix(length)) }
        return String(repeating: char, count: length - count) + self
    }
}
