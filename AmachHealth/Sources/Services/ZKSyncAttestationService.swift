// ZKSyncAttestationService.swift
// AmachHealth
//
// Submits on-chain attestations to the SecureHealthProfile V4 contract
// on ZKsync Era via the user's Privy embedded wallet.
//
// Matches the web app's client-side AttestationService pattern:
//   1. ABI-encode createAttestation(bytes32,uint8,uint40,uint40,uint16,uint16,bool)
//   2. Send via eth_sendTransaction through Privy wallet provider
//   3. Wait for tx hash
//
// No external web3 library required — ABI encoding is done inline since
// all parameter types are fixed-size.

import Foundation
#if canImport(PrivySDK)
import PrivySDK
#endif

@MainActor
final class ZKSyncAttestationService: ObservableObject {
    static let shared = ZKSyncAttestationService()

    @Published private(set) var isSubmitting = false

    // ZKsync Era Sepolia testnet
    private let chainId = 300
    private let rpcURL = "https://sepolia.era.zksync.dev"
    private let contractAddress = "0x2A8015613623A6A8D369BcDC2bd6DD202230785a"

    // Pre-computed keccak256 selectors (first 4 bytes)
    private let createAttestationSelector = "5c5c1147"
    private let hasProfileSelector = "a787c80b"
    private let verifyAttestationSelector = "c3c4ee76"

    // MerkleCommitment contract — ZKsync Era Sepolia
    // keccak256("commitGenesisRoot(bytes32,bytes32,uint32,uint32,uint32,uint8,uint8)") → 5a8b10ca
    // keccak256("hasGenesisRoot(address)") → d1b05adb
    private let merkleCommitmentAddress   = "0x2385cFF536C738C133EC4779441A591732aC7FbA"
    private let commitGenesisRootSelector = "5a8b10ca"
    private let hasGenesisRootSelector    = "d1b05adb"

    private init() {}

    // MARK: - Public API

    struct AttestationInput {
        let contentHash: String   // 0x-prefixed 32-byte hex (proofHash or data hash)
        let dataType: UInt8       // 0=DEXA, 1=Bloodwork, 2=AppleHealth, 3=CGM
        let startDate: Date
        let endDate: Date
        let completenessScore: Int  // 0-100, converted to basis points (0-10000)
        let recordCount: Int
        let coreComplete: Bool
    }

    struct AttestationResult {
        let txHash: String
    }

    // MARK: - Genesis Root (Merkle pipeline)

    /// Input for committing a Merkle genesis root on-chain.
    struct GenesisRootInput {
        let root: String        // 0x-prefixed 32-byte hex
        let startDayId: UInt32
        let endDayId: UInt32
        let leafCount: UInt32
        let rootType: UInt8     // 0 = genesis
        let syncType: UInt8     // 0 = live
    }

    struct GenesisRootResult {
        let txHash: String
    }

    /// Read hasGenesisRoot(address) from the MerkleCommitment contract via eth_call.
    func hasGenesisRoot(address: String) async throws -> Bool {
        let paddedAddress = padLeft(hexStrip(address), toBytes: 32)
        let calldata = "0x" + hasGenesisRootSelector + paddedAddress

        let result = try await ethCall(to: merkleCommitmentAddress, data: calldata)

        // Return is a single bool padded to 32 bytes — last nibble = 1 means true
        guard result.count >= 66 else { return false }
        return result.hasSuffix("1")
    }

    /// ABI-encode and submit commitGenesisRoot() to the MerkleCommitment contract.
    ///
    /// Function: commitGenesisRoot(bytes32,bytes32,uint32,uint32,uint32,uint8,uint8)
    /// Selector: 5a8b10ca
    /// Calldata: 4 + 7×32 = 228 bytes total
    func commitGenesisRoot(_ input: GenesisRootInput) async throws -> GenesisRootResult {
        let wallet = WalletService.shared
        guard wallet.isConnected, let address = wallet.address else {
            throw AttestationError.walletNotConnected
        }

        print("⛓️ [Genesis] Committing root for \(address)")
        print("⛓️ [Genesis] root=\(input.root.prefix(18))… leaves=\(input.leafCount) days=\(input.startDayId)–\(input.endDayId)")

        isSubmitting = true
        defer { isSubmitting = false }

        let calldata = encodeCommitGenesisRoot(input)
        print("⛓️ [Genesis] calldata=\(calldata.prefix(18))… (\(calldata.count) chars)")

        #if canImport(PrivySDK)
        let txHash = try await sendTransaction(
            from: address,
            to: merkleCommitmentAddress,
            data: calldata
        )
        print("⛓️ [Genesis] ✅ root committed: \(txHash)")
        return GenesisRootResult(txHash: txHash)
        #else
        throw AttestationError.privyNotAvailable
        #endif
    }

    /// ABI-encode commitGenesisRoot(bytes32,bytes32,uint32,uint32,uint32,uint8,uint8).
    /// Each param is right-justified in a 32-byte slot (standard ABI encoding for fixed types).
    ///   slot 0: root        (bytes32 — the Merkle root, no padding needed)
    ///   slot 1: prevRoot    (bytes32 — zero for genesis)
    ///   slot 2: startDayId  (uint32)
    ///   slot 3: endDayId    (uint32)
    ///   slot 4: leafCount   (uint32)
    ///   slot 5: rootType    (uint8 — 0 = genesis)
    ///   slot 6: syncType    (uint8 — 0 = live)
    private func encodeCommitGenesisRoot(_ input: GenesisRootInput) -> String {
        let root      = padLeft(hexStrip(input.root), toBytes: 32)
        let prevRoot  = padLeft("0", toBytes: 32)
        let startDay  = padLeft(String(input.startDayId, radix: 16), toBytes: 32)
        let endDay    = padLeft(String(input.endDayId,   radix: 16), toBytes: 32)
        let leafCount = padLeft(String(input.leafCount,  radix: 16), toBytes: 32)
        let rootType  = padLeft(String(input.rootType,   radix: 16), toBytes: 32)
        let syncType  = padLeft(String(input.syncType,   radix: 16), toBytes: 32)

        return "0x" + commitGenesisRootSelector
            + root + prevRoot + startDay + endDay + leafCount + rootType + syncType
    }

    /// Submit a createAttestation tx to the V4 contract.
    /// Returns the transaction hash on success.
    func createAttestation(_ input: AttestationInput) async throws -> AttestationResult {
        let wallet = WalletService.shared
        guard wallet.isConnected, let address = wallet.address else {
            print("⛓️ [Attestation] Wallet not connected — skipping on-chain anchoring")
            throw AttestationError.walletNotConnected
        }

        print("⛓️ [Attestation] Starting on-chain attestation for \(address)")
        print("⛓️ [Attestation] contentHash=\(input.contentHash.prefix(18))… dataType=\(input.dataType)")

        isSubmitting = true
        defer { isSubmitting = false }

        let hasProfile: Bool
        do {
            hasProfile = try await callHasProfile(address: address)
            print("⛓️ [Attestation] hasProfile=\(hasProfile)")
        } catch {
            print("⛓️ [Attestation] hasProfile check failed: \(error.localizedDescription)")
            throw error
        }

        guard hasProfile else {
            print("⛓️ [Attestation] No on-chain profile — cannot attest")
            throw AttestationError.noProfile
        }

        let calldata = encodeCreateAttestation(input)
        print("⛓️ [Attestation] Submitting tx to \(contractAddress) (\(calldata.count) chars calldata)")

        #if canImport(PrivySDK)
        let txHash = try await sendTransaction(
            from: address,
            to: contractAddress,
            data: calldata
        )
        print("⛓️ [Attestation] ✅ tx submitted: \(txHash)")
        return AttestationResult(txHash: txHash)
        #else
        print("⛓️ [Attestation] PrivySDK not available")
        throw AttestationError.privyNotAvailable
        #endif
    }

    /// Check if a contentHash is already attested for a user (read-only call).
    func isAttested(address: String, contentHash: String) async throws -> Bool {
        let paddedAddress = padLeft(hexStrip(address), toBytes: 32)
        let paddedHash = padLeft(hexStrip(contentHash), toBytes: 32)
        let calldata = "0x" + verifyAttestationSelector + paddedAddress + paddedHash

        let result = try await ethCall(to: contractAddress, data: calldata)

        // First 32 bytes of return = bool (exists)
        guard result.count >= 66 else { return false }  // "0x" + 64 hex chars
        let existsByte = result.suffix(from: result.index(result.startIndex, offsetBy: 2)).prefix(64)
        return existsByte.hasSuffix("1")
    }

    // MARK: - ABI Encoding

    /// Encode createAttestation(bytes32,uint8,uint40,uint40,uint16,uint16,bool)
    /// All fixed-size types → each padded to 32 bytes, concatenated after the 4-byte selector.
    private func encodeCreateAttestation(_ input: AttestationInput) -> String {
        let contentHash = padLeft(hexStrip(input.contentHash), toBytes: 32)
        let dataType = padLeft(String(input.dataType, radix: 16), toBytes: 32)

        let startTimestamp = UInt64(input.startDate.timeIntervalSince1970)
        var endTimestamp = UInt64(input.endDate.timeIntervalSince1970)
        if endTimestamp <= startTimestamp { endTimestamp = startTimestamp + 1 }

        let startDate = padLeft(String(startTimestamp, radix: 16), toBytes: 32)
        let endDate = padLeft(String(endTimestamp, radix: 16), toBytes: 32)

        let scoreBasisPoints = min(input.completenessScore * 100, 10000)
        let score = padLeft(String(scoreBasisPoints, radix: 16), toBytes: 32)
        let recordCount = padLeft(String(min(input.recordCount, 65535), radix: 16), toBytes: 32)
        let coreComplete = padLeft(input.coreComplete ? "1" : "0", toBytes: 32)

        return "0x" + createAttestationSelector
            + contentHash + dataType + startDate + endDate
            + score + recordCount + coreComplete
    }

    // MARK: - RPC Helpers

    #if canImport(PrivySDK)
    /// Send a transaction via the Privy embedded wallet.
    private func sendTransaction(from: String, to: String, data: String) async throws -> String {
        let privy = WalletService.shared
        guard privy.isConnected else { throw AttestationError.walletNotConnected }

        // Access Privy SDK internals through WalletService's signing path.
        // We use eth_sendTransaction which Privy's embedded wallet supports.
        let txHash = try await privy.sendTransaction(to: to, data: data, chainId: chainId)
        return txHash
    }
    #endif

    /// Read-only eth_call via JSON-RPC (no wallet needed).
    private func ethCall(to: String, data: String) async throws -> String {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_call",
            "params": [
                ["to": to, "data": data] as [String: String],
                "latest"
            ] as [Any]
        ]

        guard let url = URL(string: rpcURL) else {
            throw AttestationError.rpcError("Invalid RPC URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let error = json?["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw AttestationError.rpcError(message)
        }

        guard let result = json?["result"] as? String else {
            throw AttestationError.rpcError("No result from eth_call")
        }
        return result
    }

    /// Check hasProfile(address) via eth_call.
    private func callHasProfile(address: String) async throws -> Bool {
        let paddedAddress = padLeft(hexStrip(address), toBytes: 32)
        let calldata = "0x" + hasProfileSelector + paddedAddress

        let result = try await ethCall(to: contractAddress, data: calldata)

        // Return value is a single bool (32 bytes)
        guard result.count >= 66 else { return false }
        return result.hasSuffix("1")
    }

    // MARK: - Hex Utilities

    /// Remove "0x" prefix if present.
    private func hexStrip(_ hex: String) -> String {
        hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
    }

    /// Left-pad a hex string to the specified number of bytes (each byte = 2 hex chars).
    private func padLeft(_ hex: String, toBytes: Int) -> String {
        let targetLength = toBytes * 2
        guard hex.count < targetLength else {
            return String(hex.suffix(targetLength))
        }
        return String(repeating: "0", count: targetLength - hex.count) + hex
    }
}

// MARK: - Errors

enum AttestationError: LocalizedError {
    case walletNotConnected
    case noProfile
    case privyNotAvailable
    case rpcError(String)
    case transactionFailed(String)
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .walletNotConnected:
            return "Please connect your wallet first"
        case .noProfile:
            return "You need an on-chain health profile before creating attestations. Set up your profile in the Wallet section first."
        case .privyNotAvailable:
            return "Privy SDK not available"
        case .rpcError(let msg):
            return "Blockchain error: \(msg)"
        case .transactionFailed(let msg):
            return "Transaction failed: \(msg)"
        case .notImplemented(let msg):
            return "Not implemented: \(msg)"
        }
    }
}
