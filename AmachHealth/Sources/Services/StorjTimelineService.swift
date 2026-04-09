// StorjTimelineService.swift
// AmachHealth
//
// Storj I/O adapter for timeline events — injectable for testing.
// Provides fetch / save / delete / syncAll, keeping business logic
// (caching, merge, attestation) in TimelineService and pure Storj
// transport here.
//
// After every successful Storj upload, saveEvent fires a non-blocking
// on-chain registration via addHealthEventWithStorj on SecureHealthProfileV3.
//
// TimelineService delegates all Storj calls here; tests inject a mock
// that conforms to TimelineAPIProtocol.

import Foundation

// MARK: - Protocol

/// Minimal Storj operations that StorjTimelineService needs from AmachAPIClient.
/// AmachAPIClient already implements all three methods; conformance is declared
/// via extension at the bottom of this file.
protocol TimelineAPIProtocol {
    func storeTimelineEvent(
        event: TimelineEvent,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult

    func listTimelineEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [TimelineEvent]

    func deleteTimelineEvent(
        eventId: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws
}

// MARK: - StorjTimelineService

/// Pure Storj transport for timeline events.
/// Thread-safe — no actor isolation; all async/await.
final class StorjTimelineService {

    static let shared = StorjTimelineService()

    private let api: any TimelineAPIProtocol

    init(api: any TimelineAPIProtocol = AmachAPIClient.shared) {
        self.api = api
    }

    // MARK: - Public interface

    /// Download all timeline events stored for `walletAddress`.
    func fetchEvents(
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> [TimelineEvent] {
        try await api.listTimelineEvents(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
    }

    /// Upload a single event to Storj and register it on-chain.
    /// The Storj upload is the authoritative step (throws on failure).
    /// On-chain registration is best-effort — failures are logged but do not throw.
    @discardableResult
    func saveEvent(
        _ event: TimelineEvent,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws -> StorjStoreResult {
        let result = try await api.storeTimelineEvent(
            event: event,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
        // Fire-and-forget — on-chain failures must not block or fail the Storj upload.
        Task {
            do {
                try await registerOnChain(event: event, result: result)
            } catch {
                print("⛓️ [Timeline] On-chain registration failed (non-critical): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Remove an event from Storj by its string id.
    /// Idempotent — no-op if the event is not found on Storj.
    func deleteEvent(
        id: String,
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws {
        try await api.deleteTimelineEvent(
            eventId: id,
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
    }

    /// Replace the full Storj timeline with `events`.
    /// - Deletes any Storj objects whose event ID is absent from `events`.
    /// - Uploads all events in `events` (new and updated).
    /// Storj is the source of truth after this call.
    func syncAll(
        _ events: [TimelineEvent],
        walletAddress: String,
        encryptionKey: WalletEncryptionKey
    ) async throws {
        let existing = try await api.listTimelineEvents(
            walletAddress: walletAddress,
            encryptionKey: encryptionKey
        )
        let newIds = Set(events.map(\.id))

        // Remove stale events concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for stale in existing where !newIds.contains(stale.id) {
                let staleid = stale.id
                group.addTask { [api] in
                    try await api.deleteTimelineEvent(
                        eventId: staleid,
                        walletAddress: walletAddress,
                        encryptionKey: encryptionKey
                    )
                }
            }
            try await group.waitForAll()
        }

        // Upload all events sequentially to avoid hammering the backend
        for event in events {
            try await api.storeTimelineEvent(
                event: event,
                walletAddress: walletAddress,
                encryptionKey: encryptionKey
            )
        }
    }

    // MARK: - On-chain Registration

    /// SecureHealthProfileV3 UUPS proxy on ZKsync Era Sepolia.
    private let contractAddress = "0x2A8015613623A6A8D369BcDC2bd6DD202230785a"
    private let chainId = 300  // ZKsync Era Sepolia

    /// Pre-compute the 4-byte selector for addHealthEventWithStorj(bytes32,uint256,string,bytes32).
    /// keccak256("addHealthEventWithStorj(bytes32,uint256,string,bytes32)")[0:4]
    private lazy var addHealthEventWithStorjSelector: String = {
        let sig = "addHealthEventWithStorj(bytes32,uint256,string,bytes32)"
        let hash = Keccak256.hash(Array(sig.utf8))
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }()

    /// Register a timeline event on-chain after a successful Storj upload.
    ///
    /// Encoding:
    ///   searchTag   = keccak256(keccak256(eventType UTF-8) ++ storjUri bytes ++ contentHash bytes32)
    ///   timestamp   = Unix seconds (UInt64)
    ///   calldata    = addHealthEventWithStorj(searchTag, timestamp, storjUri, contentHash)
    ///
    /// The string parameter uses standard ABI dynamic encoding (offset in head, data in tail).
    private func registerOnChain(event: TimelineEvent, result: StorjStoreResult) async throws {
        // Wallet must be connected; non-connected is a silent skip, not an error.
        let wallet = WalletService.shared
        guard await wallet.isConnected else {
            print("⛓️ [Timeline] Wallet not connected — skipping on-chain registration")
            return
        }

        // contentHash bytes: try to decode as 32-byte hex; fall back to hashing the string.
        let contentHashBytes = hexTo32Bytes(result.contentHash)
            ?? Keccak256.hash(Array(result.contentHash.utf8))

        // searchTag = keccak256(keccak256(eventType UTF-8) ++ storjUri bytes ++ contentHash bytes32)
        let innerHash = Keccak256.hash(Array(event.eventType.rawValue.utf8))
        var packed = [UInt8]()
        packed.append(contentsOf: innerHash)                       // 32 bytes (bytes32)
        packed.append(contentsOf: Array(result.storjUri.utf8))    // variable (string, no padding for encodePacked)
        packed.append(contentsOf: contentHashBytes)                // 32 bytes (bytes32)
        let searchTagBytes = Keccak256.hash(packed)

        let timestamp = UInt64(event.timestamp.timeIntervalSince1970)

        let calldata = encodeAddHealthEventWithStorj(
            searchTag: searchTagBytes,
            timestamp: timestamp,
            storjUri: result.storjUri,
            contentHash: contentHashBytes
        )

        print("⛓️ [Timeline] Registering event \(event.id) on-chain (type=\(event.eventType.rawValue))")
        let txHash = try await wallet.sendTransaction(to: contractAddress, data: calldata, chainId: chainId)
        print("⛓️ [Timeline] ✅ Registered: \(txHash)")
    }

    // MARK: - ABI Encoding

    /// ABI-encode addHealthEventWithStorj(bytes32, uint256, string, bytes32).
    ///
    /// Layout (after 4-byte selector):
    ///   [0 ..31]  searchTag                         (bytes32, static)
    ///   [32..63]  timestamp                          (uint256, static)
    ///   [64..95]  offset to storjUri data = 128     (uint256, dynamic head)
    ///   [96..127] contentHash                        (bytes32, static)
    ///   [128..159] length of storjUri                (uint256, tail)
    ///   [160..]   storjUri UTF-8 bytes, zero-padded to 32-byte boundary
    private func encodeAddHealthEventWithStorj(
        searchTag: [UInt8],
        timestamp: UInt64,
        storjUri: String,
        contentHash: [UInt8]
    ) -> String {
        let uriBytes = Array(storjUri.utf8)

        // Head slots
        let searchTagSlot   = slot32(searchTag)
        let timestampSlot   = padLeftHex(String(timestamp, radix: 16), toBytes: 32)
        let offsetSlot      = padLeftHex(String(128, radix: 16), toBytes: 32)  // 128 = 4 × 32
        let contentHashSlot = slot32(contentHash)

        // Tail: length + data (right-padded to 32-byte boundary)
        let lengthSlot = padLeftHex(String(uriBytes.count, radix: 16), toBytes: 32)
        var paddedUri = uriBytes
        let rem = uriBytes.count % 32
        if rem != 0 { paddedUri.append(contentsOf: [UInt8](repeating: 0, count: 32 - rem)) }
        let uriHex = paddedUri.map { String(format: "%02x", $0) }.joined()

        return "0x" + addHealthEventWithStorjSelector
            + searchTagSlot + timestampSlot + offsetSlot + contentHashSlot
            + lengthSlot + uriHex
    }

    // MARK: - Hex Utilities

    /// Encode `bytes` (up to 32) as a right-justified 32-byte ABI slot.
    private func slot32(_ bytes: [UInt8]) -> String {
        let hex = bytes.prefix(32).map { String(format: "%02x", $0) }.joined()
        return padLeftHex(hex, toBytes: 32)
    }

    /// Left-pad a hex string to `toBytes` bytes (= 2×toBytes hex chars).
    private func padLeftHex(_ hex: String, toBytes: Int) -> String {
        let target = toBytes * 2
        guard hex.count < target else { return String(hex.suffix(target)) }
        return String(repeating: "0", count: target - hex.count) + hex
    }

    /// Decode a 0x-prefixed or bare 64-char hex string into 32 bytes.
    /// Returns nil if the string is not exactly 32 bytes of valid hex.
    private func hexTo32Bytes(_ hex: String) -> [UInt8]? {
        let stripped = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard stripped.count == 64 else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(32)
        var i = stripped.startIndex
        for _ in 0..<32 {
            let end = stripped.index(i, offsetBy: 2)
            guard let byte = UInt8(stripped[i..<end], radix: 16) else { return nil }
            result.append(byte)
            i = end
        }
        return result
    }
}

// MARK: - AmachAPIClient conformance

/// AmachAPIClient already has storeTimelineEvent and listTimelineEvents;
/// deleteTimelineEvent is implemented in AmachAPIClient.swift.
extension AmachAPIClient: TimelineAPIProtocol {}
