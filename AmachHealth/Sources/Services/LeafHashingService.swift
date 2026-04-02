// LeafHashingService.swift
// AmachHealth
//
// Xcode: keep OUT of the iOS app target — uses Process / desktop paths (macOS-only).
//
// Poseidon hashing bridge for Mac/CI: calls the Node hash_leaf.js script so hashes match
// the circom circuit. Not a production on-device prover; proving stays off the phone.
//
// See MerkleGenesisService for full pipeline orchestration and zk/ for circom assets.

import Foundation

// MARK: - Hashed Leaf

/// A leaf that has been Poseidon-hashed, ready for tree inclusion.
struct HashedLeaf {
    let leaf: MerkleLeaf
    let normalizedLeaf: NormalizedDailyLeaf
    let serialized: Data        // 90 bytes
    let hash: String            // Poseidon hash as decimal string (BN128 field element)
    let hashHex: String         // Poseidon hash as hex string (for display)
    let dayId: UInt32
}

// MARK: - Leaf Hashing Service

/// Computes Poseidon hashes for leaf arrays by calling the Node.js script.
///
/// The Node.js script ensures the hashes are identical to what the Circom
/// circuit produces — critical for proof generation.
@MainActor
final class LeafHashingService: ObservableObject {
    static let shared = LeafHashingService()

    @Published private(set) var isHashing = false
    @Published private(set) var hashingProgress: Double = 0

    // Path to the zk/ directory (relative to the app bundle)
    // In production this should point to the installed zk toolchain.
    private var zkScriptPath: String {
        // Default: sibling to the iOS project
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Projects/AmachHealth-iOS/zk"
    }

    private init() {}

    // MARK: - Public API

    /// Hash an array of normalized leaves using Poseidon.
    ///
    /// - Parameter leaves: Sorted array of NormalizedDailyLeaf from MerkleNormalizationService
    /// - Returns: Array of HashedLeaf, same order as input
    func hashLeaves(_ leaves: [NormalizedDailyLeaf]) async throws -> [HashedLeaf] {
        isHashing = true
        hashingProgress = 0
        defer {
            isHashing = false
            hashingProgress = 0
        }

        // Serialize all leaves to 90-byte hex strings
        let serializedLeaves = leaves.map { normalized -> [String: Any] in
            let leaf = normalized.toMerkleLeaf()
            let serialized = leaf.serialize()
            return [
                "dayId": normalized.dayId,
                "serialized": serialized.hexEncodedString()
            ]
        }

        hashingProgress = 0.1

        // Write input to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let inputFile = tempDir.appendingPathComponent("leaves_to_hash.json")
        let outputFile = tempDir.appendingPathComponent("hashed_leaves.json")

        let inputData = try JSONSerialization.data(withJSONObject: serializedLeaves)
        try inputData.write(to: inputFile)

        hashingProgress = 0.2

        // Run Node.js hash script
        let result = try await runNodeScript(
            script: "hash_leaves_batch.js",
            args: [inputFile.path, outputFile.path]
        )

        hashingProgress = 0.8

        // Parse output
        guard FileManager.default.fileExists(atPath: outputFile.path),
              let outputData = FileManager.default.contents(atPath: outputFile.path),
              let outputArray = try JSONSerialization.jsonObject(with: outputData) as? [[String: Any]] else {
            throw LeafHashingError.scriptOutputMissing
        }

        // Build HashedLeaf array
        var hashedLeaves: [HashedLeaf] = []
        for (i, (normalized, output)) in zip(leaves, outputArray).enumerated() {
            guard let hashDecimal = output["hash"] as? String,
                  let hashHex = output["hashHex"] as? String else {
                throw LeafHashingError.invalidOutput(index: i)
            }

            let leaf = normalized.toMerkleLeaf()
            let hashedLeaf = HashedLeaf(
                leaf: leaf,
                normalizedLeaf: normalized,
                serialized: leaf.serialize(),
                hash: hashDecimal,
                hashHex: hashHex,
                dayId: normalized.dayId
            )
            hashedLeaves.append(hashedLeaf)
        }

        hashingProgress = 1.0
        return hashedLeaves
    }

    /// Export normalized leaves to the format expected by the Node.js pipeline.
    /// Returns the path to the exported JSON file.
    func exportNormalizedLeaves(_ leaves: [NormalizedDailyLeaf]) throws -> URL {
        let output = leaves.map { normalized -> [String: Any] in
            let leaf = normalized.toMerkleLeaf()
            return [
                "dayId": normalized.dayId,
                "serialized": leaf.serialize().hexEncodedString(),
                "steps": normalized.steps,
                "activeEnergy": normalized.activeEnergy,
                "exerciseMins": normalized.exerciseMins,
                "hrv": normalized.hrv,
                "restingHR": normalized.restingHR,
                "sleepMins": normalized.sleepMins,
                "workoutCount": normalized.workoutCount,
                "sourceCount": normalized.sourceCount,
                "dataFlags": normalized.dataFlags
            ] as [String: Any]
        }

        let data = try JSONSerialization.data(withJSONObject: output, options: .prettyPrinted)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("normalized_leaves.json")
        try data.write(to: url)

        return url
    }

    // MARK: - Script Runner

    private func runNodeScript(script: String, args: [String]) async throws -> String {
        let scriptPath = "\(zkScriptPath)/scripts/\(script)"

        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw LeafHashingError.scriptNotFound(scriptPath)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", scriptPath] + args

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                } else {
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Unknown error"
                    continuation.resume(throwing: LeafHashingError.scriptFailed(err))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Batch Hash Script (companion to hash_leaf.js)

/// Creates a batch hashing script inline — this is the Node.js code called by the service.
/// In production this would be bundled with the app or installed via NPM.
extension LeafHashingService {
    static let batchHashScript = """
    // hash_leaves_batch.js — called by LeafHashingService.swift
    'use strict';
    const { hashLeaf } = require('./hash_leaf');
    const fs = require('fs');

    const inputPath = process.argv[2];
    const outputPath = process.argv[3];

    const leaves = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
    const output = leaves.map(leaf => {
        const buf = Buffer.from(leaf.serialized, 'hex');
        const hash = hashLeaf(buf);
        return {
            dayId: leaf.dayId,
            hash: hash.toString(10),
            hashHex: '0x' + hash.toString(16)
        };
    });

    fs.writeFileSync(outputPath, JSON.stringify(output, null, 2));
    """
}

// MARK: - Errors

enum LeafHashingError: LocalizedError {
    case scriptNotFound(String)
    case scriptFailed(String)
    case scriptOutputMissing
    case invalidOutput(index: Int)
    case nodeNotAvailable

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let path):
            return "Node.js hash script not found at: \(path)"
        case .scriptFailed(let msg):
            return "Hash script failed: \(msg)"
        case .scriptOutputMissing:
            return "Hash script did not produce output file"
        case .invalidOutput(let index):
            return "Invalid hash output at index \(index)"
        case .nodeNotAvailable:
            return "Node.js runtime not available"
        }
    }
}

// MARK: - Data Hex Helper

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}
