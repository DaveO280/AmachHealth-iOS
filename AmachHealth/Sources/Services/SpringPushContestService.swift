// SpringPushContestService.swift
// AmachHealth
//
// Read-only client for the Spring Push escrow contract. Reads two values:
//   - state()              — uint8 ContestState (0..5)
//   - registered(address)  — bool, true if the user joined this season
//
// These are the only on-chain facts the auto-trigger needs. Writes go
// through the web wallet (proof submission, prize claim) — iOS never
// signs Spring Push transactions.
//
// Mirrors ZKSyncAttestationService's eth_call pattern: same RPC URL,
// same hex helpers, same 4-byte selector + 32-byte padded argument
// encoding. Selectors below were computed via `keccak("state()")` and
// `keccak("registered(address)")` and pinned as constants — the web
// reads the same contract through the ESCROW_ABI in SpringPushWidget.tsx.

import Foundation

/// Lifecycle states of `SpringPushEscrowV1.state`. Values match the
/// Solidity enum exactly so they can be decoded from the raw uint8.
enum ContestState: UInt8 {
    case uninitialized = 0
    case registrationOpen = 1
    case active = 2
    case claiming = 3
    case finished = 4
    case failed = 5

    /// True when the baseline leaves should be on Storj: the user has
    /// registered, the contest is running, and leaves are immutable
    /// for the rest of the season.
    var isActive: Bool { self == .active }

    /// True when the user is in the claim window: finish leaves must be
    /// on Storj before they can generate an improvement proof.
    var isClaiming: Bool { self == .claiming }
}

@MainActor
final class SpringPushContestService: ObservableObject {
    static let shared = SpringPushContestService()

    // MARK: - Network config
    //
    // zkSync Era Sepolia. Mirrors the address pinned in
    // `Amach-Website/src/lib/networkConfig.ts` (SPRING_PUSH_ESCROW_CONTRACT).
    // Mainnet uses a different deployment; when iOS gains a mainnet
    // toggle this should pivot off `WalletService.chainId`.
    private let rpcURL = "https://sepolia.era.zksync.dev"
    private let escrowAddress = "0x877BEe22bDC7eB38ec02a97872A7E3E615646CE8"

    // Pre-computed function selectors. keccak256(signature)[..4]:
    //   state()              → c19d93fb
    //   registered(address)  → b2dd5c07
    private let stateSelector = "c19d93fb"
    private let registeredSelector = "b2dd5c07"

    private init() {}

    // MARK: - Public API

    /// Read the current contest state. Throws on RPC error or malformed
    /// response; returns `.uninitialized` for unrecognised state values
    /// (defensive — the on-chain enum should always be 0..5).
    func fetchState() async throws -> ContestState {
        let calldata = "0x" + stateSelector
        let raw = try await ethCall(to: escrowAddress, data: calldata)
        let value = try Self.decodeUInt8(from: raw)
        return ContestState(rawValue: value) ?? .uninitialized
    }

    /// Read `registered(address)` for the given wallet. Throws on RPC
    /// error. Returns false for malformed responses.
    func fetchRegistered(address: String) async throws -> Bool {
        let padded = Self.padLeftHex(Self.hexStrip(address), toBytes: 32)
        let calldata = "0x" + registeredSelector + padded
        let raw = try await ethCall(to: escrowAddress, data: calldata)
        return Self.decodeBool(from: raw)
    }

    /// Convenience: fetch both `state()` and `registered(wallet)` in
    /// parallel. The two RPC calls are independent; bundling them
    /// halves the auto-sync's worst-case latency.
    func fetchStateAndRegistration(address: String) async throws -> (state: ContestState, registered: Bool) {
        async let stateTask = fetchState()
        async let registeredTask = fetchRegistered(address: address)
        return try await (state: stateTask, registered: registeredTask)
    }

    // MARK: - RPC

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
            throw ContestServiceError.rpcError("Invalid RPC URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = json?["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw ContestServiceError.rpcError(message)
        }
        guard let result = json?["result"] as? String else {
            throw ContestServiceError.rpcError("No result from eth_call")
        }
        return result
    }

    // MARK: - Decoding helpers
    //
    // Exposed `internal static` so the auto-trigger unit tests can
    // exercise the decoders without hitting the network. Kept inside
    // the type so they share namespace with the selectors above.

    /// Decode a 32-byte ABI uint8 word (`0x000…0XX`) into a Swift UInt8.
    /// Throws if the result is shorter than 32 hex chars (after `0x`).
    nonisolated static func decodeUInt8(from rawHex: String) throws -> UInt8 {
        let stripped = hexStrip(rawHex)
        guard stripped.count >= 64 else {
            throw ContestServiceError.rpcError("uint8 result too short: \(rawHex)")
        }
        // The last 2 hex chars carry the uint8 value (right-aligned in 32 bytes).
        let suffix = String(stripped.suffix(2))
        guard let value = UInt8(suffix, radix: 16) else {
            throw ContestServiceError.rpcError("uint8 result not hex: \(rawHex)")
        }
        return value
    }

    /// Decode a 32-byte ABI bool word. ABI encodes `true` as `…0001` and
    /// `false` as `…0000`. Any malformed result decodes to `false`.
    nonisolated static func decodeBool(from rawHex: String) -> Bool {
        let stripped = hexStrip(rawHex)
        guard stripped.count >= 64 else { return false }
        // Last hex char carries the low bit.
        return stripped.last == "1"
    }

    nonisolated static func hexStrip(_ hex: String) -> String {
        if hex.hasPrefix("0x") || hex.hasPrefix("0X") { return String(hex.dropFirst(2)) }
        return hex
    }

    nonisolated static func padLeftHex(_ hex: String, toBytes: Int) -> String {
        let targetLength = toBytes * 2
        if hex.count >= targetLength { return String(hex.suffix(targetLength)) }
        return String(repeating: "0", count: targetLength - hex.count) + hex
    }
}

enum ContestServiceError: LocalizedError {
    case rpcError(String)
    var errorDescription: String? {
        switch self {
        case .rpcError(let msg): return "Spring Push RPC: \(msg)"
        }
    }
}
