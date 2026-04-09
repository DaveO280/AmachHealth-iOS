// StorjTimelineService.swift
// AmachHealth
//
// Storj I/O adapter for timeline events — injectable for testing.
// Provides fetch / save / delete / syncAll, keeping business logic
// (caching, merge, attestation) in TimelineService and pure Storj
// transport here.
//
// After each successful Storj upload, registerEventOnChain() submits
// addHealthEventV2() to the SecureHealthProfileV3 contract so the
// website's readHealthTimeline() can discover the event via its
// eventStorjUri / eventContentHash accessors.
//
// TimelineService delegates all Storj calls here; tests inject a mock
// that conforms to TimelineAPIProtocol.

import CryptoKit
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

    // MARK: - Chain constants (SecureHealthProfileV3, zkSync Era Sepolia)

    private static let chainId = 300
    private static let contractAddress = "0x2A8015613623A6A8D369BcDC2bd6DD202230785a"
    /// keccak256("addHealthEventV2(bytes32,string,bytes32,bytes32)") → first 4 bytes
    private static let addHealthEventV2Selector = "1c7eec3d"

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
        // Fire chain registration without blocking the caller; errors are non-fatal.
        let capturedResult = result
        let capturedEvent = event
        Task {
            await self.registerEventOnChain(
                storjUri: capturedResult.storjUri,
                contentHash: capturedResult.contentHash,
                event: capturedEvent,
                walletAddress: walletAddress
            )
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

    // MARK: - On-chain registration

    /// Submit addHealthEventV2() to SecureHealthProfileV3 so the website's
    /// readHealthTimeline() can see events uploaded from iOS.
    ///
    /// ABI: addHealthEventV2(bytes32 searchTag, string storjUri, bytes32 contentHash, bytes32 eventHash)
    /// Selector: 1c7eec3d
    ///
    /// - searchTag: SHA256(eventType.rawValue UTF-8) as bytes32
    /// - eventHash: SHA256(searchTag_bytes32 ‖ storjUri_utf8 ‖ contentHash_bytes32) as bytes32
    ///   (SHA256 used in place of keccak256, which is unavailable in CryptoKit;
    ///    the contract stores this value as-is and does not verify it on read)
    @MainActor
    private func registerEventOnChain(
        storjUri: String,
        contentHash: String,
        event: TimelineEvent,
        walletAddress: String
    ) async {
        let wallet = WalletService.shared
        guard wallet.isConnected else {
            print("⛓️ [Timeline] Wallet not connected — skipping on-chain registration")
            return
        }

        // Normalise contentHash: strip 0x, must be 64 hex chars (32 bytes)
        let contentHashRaw = contentHash.hasPrefix("0x") ? String(contentHash.dropFirst(2)) : contentHash
        guard contentHashRaw.count == 64 else {
            print("⛓️ [Timeline] Invalid contentHash length \(contentHashRaw.count) — skipping")
            return
        }

        // searchTag = SHA256(eventType UTF-8) as bytes32 hex
        let searchTagDigest = SHA256.hash(data: Data(event.eventType.rawValue.utf8))
        let searchTagHex = searchTagDigest.map { String(format: "%02x", $0) }.joined()

        // eventHash = SHA256(searchTag_bytes32 || storjUri_utf8 || contentHash_bytes32)
        var packed = Data()
        packed.append(contentsOf: Self.hexToBytes(searchTagHex))   // 32 bytes
        packed.append(Data(storjUri.utf8))                          // variable
        packed.append(contentsOf: Self.hexToBytes(contentHashRaw))  // 32 bytes
        let eventHashDigest = SHA256.hash(data: packed)
        let eventHashHex = eventHashDigest.map { String(format: "%02x", $0) }.joined()

        let calldata = Self.encodeAddHealthEventV2(
            searchTag: searchTagHex,
            storjUri: storjUri,
            contentHash: contentHashRaw,
            eventHash: eventHashHex
        )

        print("⛓️ [Timeline] Registering event \(event.id) on-chain…")
        print("⛓️ [Timeline] searchTag=\(searchTagHex.prefix(16))… storjUri=\(storjUri.prefix(40))…")

        do {
            let txHash = try await wallet.sendTransaction(
                to: Self.contractAddress,
                data: calldata,
                chainId: Self.chainId
            )
            print("⛓️ [Timeline] ✅ registered on-chain: \(txHash)")
        } catch {
            print("⛓️ [Timeline] ⚠️ on-chain registration failed (non-blocking): \(error.localizedDescription)")
        }
    }

    // MARK: - ABI encoding helpers

    /// ABI-encode addHealthEventV2(bytes32, string, bytes32, bytes32).
    ///
    /// Layout (selector excluded):
    ///   head slot 0 (offset   0): searchTag  — bytes32, static
    ///   head slot 1 (offset  32): offset to storjUri tail = 128 (0x80) — uint256
    ///   head slot 2 (offset  64): contentHash — bytes32, static
    ///   head slot 3 (offset  96): eventHash   — bytes32, static
    ///   tail slot 4 (offset 128): length of storjUri string — uint256
    ///   tail slot 5+ (offset 160): storjUri UTF-8 bytes, right-padded to 32-byte multiple
    private static func encodeAddHealthEventV2(
        searchTag: String,   // 64 hex chars, no 0x prefix
        storjUri: String,
        contentHash: String, // 64 hex chars, no 0x prefix
        eventHash: String    // 64 hex chars, no 0x prefix
    ) -> String {
        let uriBytes = Data(storjUri.utf8)
        let uriLen = uriBytes.count

        // Length slot: storjUri byte count, left-padded to 32 bytes
        let lenSlot = padLeft(String(uriLen, radix: 16), toBytes: 32)

        // storjUri bytes, right-padded to next 32-byte boundary
        let uriHex = uriBytes.map { String(format: "%02x", $0) }.joined()
        let pad = uriLen % 32 == 0 ? 0 : 32 - (uriLen % 32)
        let paddedUriHex = uriHex + String(repeating: "0", count: pad * 2)

        // head slot 1: offset to tail = 4 slots × 32 bytes = 128 = 0x80
        let offsetSlot = padLeft("80", toBytes: 32)

        return "0x" + addHealthEventV2Selector
            + padLeft(searchTag, toBytes: 32)    // slot 0
            + offsetSlot                          // slot 1
            + padLeft(contentHash, toBytes: 32)   // slot 2
            + padLeft(eventHash, toBytes: 32)     // slot 3
            + lenSlot                             // tail: length
            + paddedUriHex                        // tail: uri bytes
    }

    /// Left-pad a hex string to `toBytes` bytes (each byte = 2 hex chars).
    private static func padLeft(_ hex: String, toBytes: Int) -> String {
        let target = toBytes * 2
        if hex.count >= target { return String(hex.suffix(target)) }
        return String(repeating: "0", count: target - hex.count) + hex
    }

    /// Convert a lowercase hex string (no 0x prefix) to a [UInt8] array.
    private static func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16) ?? 0)
            i = j
        }
        return bytes
    }
}

// MARK: - AmachAPIClient conformance


/// AmachAPIClient already has storeTimelineEvent and listTimelineEvents;
/// deleteTimelineEvent is implemented in AmachAPIClient.swift.
extension AmachAPIClient: TimelineAPIProtocol {}
