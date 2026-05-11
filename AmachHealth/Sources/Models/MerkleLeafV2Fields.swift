// MerkleLeafV2Fields.swift
// AmachHealth
//
// Wire-format mirror of the TypeScript `AmachLeafV2Fields` in
// `Amach-Website/src/zk/improvementWitnessBuilder.ts`. Sent to
// `POST /api/merkle/v2/upload`, which serializes each leaf into its
// canonical 124-byte form, Poseidon4-hashes it server-side, and stores
// `{ leaves: [{ serializedHex, hashDec, ...structuredFields }] }` to
// Storj under the dataType the web-side proof builder reads from.
//
// Byte fields (`reservedPayload`, `sourceHash`) are hex strings because
// JSON has no native bytes type. The server-side `wireLeafToFields`
// helper decodes them before handing off to `serializeLeafV2`.
//
// Why server-side hashing: ZK proving stays off-device, and the canonical
// BN254/Poseidon implementation lives in the website. iOS only normalizes
// HealthKit into this shape and POSTs JSON.

import Foundation

/// One day of v2 health data as it crosses the wire to the website.
///
/// The integer-encoding conventions (e.g. `weight` in grams/10, percentages
/// in basis points) match the TS `AmachLeafV2Fields` interface verbatim.
/// Do not change field types or names without coordinating with the
/// `improvementWitnessBuilder.ts` v2 leaf-format spec — any drift breaks
/// every proof built against trees uploaded by older iOS clients.
struct MerkleLeafV2Fields: Codable, Equatable {
    /// Hex wallet (with or without `0x`). Right-aligned into 32 bytes
    /// server-side; for EVM 20-byte addresses this produces 12 zero bytes
    /// + the 20 wallet bytes.
    let wallet: String
    let dayId: UInt32
    let timezoneOffset: Int16

    // v1-equivalent metrics (same semantics as MerkleLeaf in v1)
    let steps: UInt32
    let activeEnergy: UInt32       // kcal * 100
    let exerciseMins: UInt16
    let hrv: UInt16                // ms * 10, 0 if absent
    let restingHR: UInt16          // bpm * 10, 0 if absent
    let sleepMins: UInt16
    let workoutCount: UInt8
    let sourceCount: UInt8
    /// Full 32-bit data flags. v1 used 16 bits; v2 widens for future bits
    /// (e.g. sleep-stage presence, body-comp presence).
    let dataFlags: UInt32

    // v2-only metrics. The improvement circuit's default metric pointer
    // is `vo2max` (chunk 2, byte offset 2 — see METRIC_POINTER in the TS
    // builder). All v2-only fields are 0 until the iOS HealthKit pipeline
    // gains support for them; see SpringPushLeavesService for the TODO.
    let vo2max: UInt16             // ml/(kg·min) * 10
    let weight: UInt16             // grams / 10
    let bodyFatPct: UInt16         // % * 100 (basis points)
    let leanMass: UInt16           // grams / 10
    let deepSleepMins: UInt16
    let remSleepMins: UInt16
    let lightSleepMins: UInt16
    let awakeMins: UInt16

    /// Up to 12 reserved payload bytes, encoded as hex. `nil` ⇒ server
    /// defaults to 12 zero bytes.
    var reservedPayload: String?
    /// Up to 32 source-hash bytes, encoded as hex. `nil` ⇒ server defaults
    /// to 32 zero bytes.
    var sourceHash: String?

    // Envelope overrides — nearly always `nil`. Server defaults to
    // the v2 daily_summary contract (version=0x02, leafType=0x00,
    // schemaVersion=0x01, reservedEnvelope=0x00). Only set these when
    // deliberately producing malformed leaves for validator tests.
    var version: UInt8?
    var leafType: UInt8?
    var schemaVersion: UInt8?
    var reservedEnvelope: UInt8?
}

// MARK: - Construction from a v1-normalized daily leaf

extension MerkleLeafV2Fields {
    /// Build a v2 wire leaf from a v1-normalized daily leaf.
    ///
    /// v2-only metrics (vo2max, body comp, sleep stages) are zeroed; the
    /// existing `MerkleNormalizationService` only emits v1 fields. When
    /// the normalization pipeline gains v2 support, populate them here
    /// and remove the TODO.
    init(from leaf: NormalizedDailyLeaf, walletAddress: String) {
        self.wallet = walletAddress
        self.dayId = leaf.dayId
        self.timezoneOffset = Int16(leaf.timezone.secondsFromGMT() / 60)
        self.steps = leaf.steps
        self.activeEnergy = leaf.activeEnergy
        self.exerciseMins = leaf.exerciseMins
        self.hrv = leaf.hrv
        self.restingHR = leaf.restingHR
        self.sleepMins = leaf.sleepMins
        self.workoutCount = leaf.workoutCount
        self.sourceCount = leaf.sourceCount
        self.dataFlags = UInt32(leaf.dataFlags)
        // TODO: populate v2-only metrics once MerkleNormalizationService
        // emits them (HKQuantityTypeIdentifierVO2Max, BodyMass,
        // BodyFatPercentage, LeanBodyMass; sleep-stage HKCategorySamples).
        // Until then, the Spring Push improvement circuit's vo2max metric
        // pointer will read 0 for every leaf — which is fine for plumbing
        // tests but produces a divide-by-zero in the proof builder.
        self.vo2max = 0
        self.weight = 0
        self.bodyFatPct = 0
        self.leanMass = 0
        self.deepSleepMins = 0
        self.remSleepMins = 0
        self.lightSleepMins = 0
        self.awakeMins = 0
        self.reservedPayload = nil
        self.sourceHash = leaf.sourceHash.merkleV2HexString()
        self.version = nil
        self.leafType = nil
        self.schemaVersion = nil
        self.reservedEnvelope = nil
    }
}

private extension Data {
    func merkleV2HexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
