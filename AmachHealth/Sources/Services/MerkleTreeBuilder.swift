// MerkleTreeBuilder.swift
// AmachHealth
//
// Xcode: keep OUT of the iOS app target (genesis / proving off-device on Mac or backend).
//
// Swift-side Merkle tree management and Storj storage coordination.
//
// This service:
//   - Manages the genesis tree structure (loaded from / saved to Storj)
//   - Builds the Storj storage payload (tree.json + leaves.json + metadata.json)
//   - Coordinates with ZKSyncAttestationService for on-chain commitment
//
// NOTE: Poseidon hashing / tree build may run in Node (see zk/scripts/build_tree.js).
//       This service coordinates storage and on-chain attestation from Mac/CLI flows.
//
// Storj storage layout:
//   storj://amach-health-{bucket}/merkle/{walletAddress}/genesis/
//     tree.json.enc     — encrypted full tree (all nodes, all levels)
//     leaves.json.enc   — encrypted leaf preimages (raw metric vectors)
//     metadata.json     — unencrypted: root hash, day range, leaf count, timestamp

import Foundation

// MARK: - Tree Result

/// The in-memory representation of a built Merkle tree.
/// Loaded from Storj or built fresh from normalization output.
struct MerkleTreeResult {
    let root: String                // Poseidon hash as hex string (64 chars, no 0x)
    let rootPadded: String          // 0x-prefixed, 66 chars total
    let leafCount: Int
    let treeDepth: Int
    let treeSize: Int               // padded to power of 2
    let startDayId: UInt32
    let endDayId: UInt32
    let generatedAt: Date

    /// Full tree structure — needed for proof generation
    /// tree[0] = leaf hashes, tree[depth] = [root]
    let tree: [[String]]           // hex strings
    let leafHashes: [String]       // hex strings, only real leaves

    var rootBytes32: String { rootPadded }  // alias for contract call
}

/// Metadata stored unencrypted alongside each Merkle commitment.
struct MerkleCommitmentMetadata: Codable {
    let rootHash: String
    let rootHashPadded: String
    let startDayId: UInt32
    let endDayId: UInt32
    let leafCount: Int
    let treeDepth: Int
    let treeSize: Int
    let generatedAt: String        // ISO8601
    let platform: String           // "ios"
    let protocolVersion: String    // "1.0"
}

// MARK: - Service

@MainActor
final class MerkleTreeBuilder: ObservableObject {
    static let shared = MerkleTreeBuilder()

    @Published private(set) var isBuilding = false
    @Published private(set) var buildProgress: Double = 0
    @Published private(set) var lastBuiltTree: MerkleTreeResult?
    @Published private(set) var lastError: String?

    private let api = AmachAPIClient.shared
    private let zkScriptBase: String

    private init() {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        zkScriptBase = "\(home)/Projects/AmachHealth-iOS/zk"
        #else
        zkScriptBase = ""
        #endif
    }

    // MARK: - Build Genesis Tree

    /// Build the genesis Merkle tree from a set of hashed leaves.
    ///
    /// Steps:
    /// 1. Export normalized leaves to JSON
    /// 2. Run Node.js build_tree.js
    /// 3. Parse the genesis_tree.json output
    /// 4. Return MerkleTreeResult
    ///
    /// - Parameter hashedLeaves: From LeafHashingService.hashLeaves()
    /// - Returns: MerkleTreeResult ready for Storj upload and on-chain commitment
    func buildGenesisTree(from hashedLeaves: [HashedLeaf]) async throws -> MerkleTreeResult {
        guard !hashedLeaves.isEmpty else {
            throw MerkleTreeError.noLeaves
        }

        isBuilding = true
        buildProgress = 0
        lastError = nil
        defer {
            isBuilding = false
        }

        // Export hashed leaves to file for Node.js script
        buildProgress = 0.1
        let inputFile = try exportHashedLeaves(hashedLeaves)
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("genesis_tree_output.json")

        // Run Node.js tree builder
        buildProgress = 0.3
        let scriptPath = "\(zkScriptBase)/scripts/build_tree_cli.js"

        _ = try await runNodeScript(
            script: scriptPath,
            args: [inputFile.path, outputFile.path]
        )

        buildProgress = 0.7

        // Parse output
        guard FileManager.default.fileExists(atPath: outputFile.path),
              let data = FileManager.default.contents(atPath: outputFile.path),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MerkleTreeError.buildFailed("Node.js script produced no output")
        }

        let result = try parseTreeOutput(json, leaves: hashedLeaves)

        buildProgress = 1.0
        lastBuiltTree = result
        return result
    }

    // MARK: - Storj Storage

    /// Build the Storj payload for a genesis tree commitment.
    ///
    /// Returns three objects ready for Storj upload:
    ///   - encryptedTree: encrypted tree.json
    ///   - encryptedLeaves: encrypted leaves.json
    ///   - metadata: unencrypted metadata.json (safe to store publicly)
    func buildStorjPayload(
        tree: MerkleTreeResult,
        hashedLeaves: [HashedLeaf],
        walletAddress: String
    ) throws -> MerkleStorjPayload {

        // Build tree JSON for encryption
        let treeData: [String: Any] = [
            "root": tree.root,
            "rootPadded": tree.rootPadded,
            "tree": tree.tree,
            "leafHashes": tree.leafHashes,
            "leafCount": tree.leafCount,
            "treeSize": tree.treeSize,
            "depth": tree.treeDepth
        ]

        // Build leaves JSON for encryption (contains health metrics — encrypt this)
        let leavesData = hashedLeaves.map { hl -> [String: Any] in
            return [
                "dayId": hl.dayId,
                "serialized": hl.serialized.hexEncodedString(),
                "hash": hl.hash,
                "steps": hl.normalizedLeaf.steps,
                "activeEnergy": hl.normalizedLeaf.activeEnergy,
                "exerciseMins": hl.normalizedLeaf.exerciseMins,
                "hrv": hl.normalizedLeaf.hrv,
                "restingHR": hl.normalizedLeaf.restingHR,
                "sleepMins": hl.normalizedLeaf.sleepMins,
                "workoutCount": hl.normalizedLeaf.workoutCount,
                "dataFlags": hl.normalizedLeaf.dataFlags
            ] as [String: Any]
        }

        // Build unencrypted metadata (safe to expose — no health values)
        let iso8601 = ISO8601DateFormatter()
        let metadata = MerkleCommitmentMetadata(
            rootHash: tree.root,
            rootHashPadded: tree.rootPadded,
            startDayId: tree.startDayId,
            endDayId: tree.endDayId,
            leafCount: tree.leafCount,
            treeDepth: tree.treeDepth,
            treeSize: tree.treeSize,
            generatedAt: iso8601.string(from: tree.generatedAt),
            platform: "ios",
            protocolVersion: "1.0"
        )

        let treeJson = try JSONSerialization.data(withJSONObject: treeData, options: .prettyPrinted)
        let leavesJson = try JSONSerialization.data(withJSONObject: leavesData, options: .prettyPrinted)
        let metadataJson = try JSONEncoder().encode(metadata)

        // Storj path
        let storjPath = "merkle/\(walletAddress.lowercased())/genesis"

        return MerkleStorjPayload(
            treeJsonData: treeJson,
            leavesJsonData: leavesJson,
            metadataJsonData: metadataJson,
            storjPath: storjPath,
            metadata: metadata
        )
    }

    // MARK: - Private Helpers

    private func exportHashedLeaves(_ leaves: [HashedLeaf]) throws -> URL {
        let output = leaves.map { hl -> [String: Any] in
            [
                "dayId": hl.dayId,
                "serialized": hl.serialized.hexEncodedString(),
                "hash": hl.hash
            ] as [String: Any]
        }

        let data = try JSONSerialization.data(withJSONObject: output)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hashed_leaves_input.json")
        try data.write(to: url)
        return url
    }

    private func parseTreeOutput(_ json: [String: Any], leaves: [HashedLeaf]) throws -> MerkleTreeResult {
        guard let root = json["root"] as? String,
              let leafCount = json["leafCount"] as? Int,
              let treeDepth = json["depth"] as? Int,
              let treeSize = json["treeSize"] as? Int,
              let treeLevels = json["tree"] as? [[String]],
              let leafHashes = json["leafHashes"] as? [String] else {
            throw MerkleTreeError.buildFailed("Invalid tree output format")
        }

        let startDayId = leaves.min(by: { $0.dayId < $1.dayId })?.dayId ?? 0
        let endDayId = leaves.max(by: { $0.dayId < $1.dayId })?.dayId ?? 0

        let rootPadded = "0x" + root.replacingOccurrences(of: "0x", with: "").padLeft(toLength: 64, with: "0")

        return MerkleTreeResult(
            root: root.replacingOccurrences(of: "0x", with: ""),
            rootPadded: rootPadded,
            leafCount: leafCount,
            treeDepth: treeDepth,
            treeSize: treeSize,
            startDayId: startDayId,
            endDayId: endDayId,
            generatedAt: Date(),
            tree: treeLevels,
            leafHashes: leafHashes
        )
    }

    private func runNodeScript(script: String, args: [String]) async throws -> String {
        #if os(macOS)
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", script] + args

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { proc in
                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown"
                    continuation.resume(throwing: MerkleTreeError.buildFailed(err))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #else
        throw MerkleTreeError.buildFailed("Node.js tree build is not available on iOS — run genesis pipeline on Mac/CI")
        #endif
    }
}

// MARK: - Storj Payload

struct MerkleStorjPayload {
    let treeJsonData: Data        // encrypt before upload
    let leavesJsonData: Data      // encrypt before upload
    let metadataJsonData: Data    // upload unencrypted
    let storjPath: String         // e.g. "merkle/0xabc.../genesis"
    let metadata: MerkleCommitmentMetadata
}

// MARK: - Errors

enum MerkleTreeError: LocalizedError {
    case noLeaves
    case buildFailed(String)
    case parseError(String)
    case storjUploadFailed(String)
    case attestationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noLeaves:
            return "No leaves provided to build tree"
        case .buildFailed(let msg):
            return "Tree build failed: \(msg)"
        case .parseError(let msg):
            return "Failed to parse tree output: \(msg)"
        case .storjUploadFailed(let msg):
            return "Storj upload failed: \(msg)"
        case .attestationFailed(let msg):
            return "On-chain attestation failed: \(msg)"
        }
    }
}

// MARK: - String Helper

private extension String {
    func padLeft(toLength length: Int, with char: Character) -> String {
        if count >= length { return String(suffix(length)) }
        return String(repeating: char, count: length - count) + self
    }
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}
