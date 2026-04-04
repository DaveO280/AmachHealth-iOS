// MerkleLeaf.swift
// AmachHealth
//
// Xcode: keep OUT of the iOS app target (shared spec for off-device proving / circom).
//
// Defines the canonical leaf schema for the Amach Health Merkle tree.
// Every leaf represents exactly one calendar day of health data for one wallet.
//
// PROTOCOL SPEC v1.0 — April 2026
// Serialization format: 90 bytes, big-endian, fixed field order.
// This spec is authoritative. Circuits must reproduce it exactly.

import Foundation
import CryptoKit

// MARK: - Merkle Leaf Struct

/// One day of normalized health data. The unit of commitment in the Merkle tree.
/// All field values are integer-encoded to eliminate floating-point ambiguity.
struct MerkleLeaf {
    let dayId: UInt32           // Days since 2024-01-01 in local timezone. 2024-01-01 = day 0.
    let wallet: Data            // 32 bytes, user wallet address (zero-padded if shorter)
    let timezoneOffset: Int16   // Minutes from UTC (e.g. -300 for EST, +330 for IST)
    let steps: UInt32           // Integer step count
    let activeEnergy: UInt32    // kcal * 100 (e.g. 350.5 kcal → 35050)
    let exerciseMins: UInt16    // Integer exercise minutes
    let hrv: UInt16             // ms * 10 (e.g. 42.3 ms → 423). 0 if absent.
    let restingHR: UInt16       // bpm * 10 (e.g. 58.0 bpm → 580). 0 if absent.
    let sleepMins: UInt16       // Integer total sleep minutes
    let workoutCount: UInt8     // Distinct workout sessions in the day
    let sourceCount: UInt8      // Distinct HealthKit source bundle IDs (capped at 255)
    let dataFlags: UInt16       // Bitmask — which metrics are present/valid
    let sourceHash: Data        // 32 bytes — SHA256 of sorted source bundle IDs
}

// MARK: - Data Flags Bitmask

/// Bitmask values for MerkleLeaf.dataFlags.
/// Set a bit to 1 when the corresponding metric has valid recorded data.
enum MerkleLeafFlag: UInt16 {
    case stepsPresent        = 0b0000_0000_0000_0001  // bit 0
    case activeEnergyPresent = 0b0000_0000_0000_0010  // bit 1
    case exerciseMinsPresent = 0b0000_0000_0000_0100  // bit 2
    case hrvPresent          = 0b0000_0000_0000_1000  // bit 3
    case restingHRPresent    = 0b0000_0000_0001_0000  // bit 4
    case sleepPresent        = 0b0000_0000_0010_0000  // bit 5
    case workoutLogged       = 0b0000_0000_0100_0000  // bit 6
    case bloodOxygenPresent  = 0b0000_0000_1000_0000  // bit 7
    case multiSourceDay      = 0b0000_0001_0000_0000  // bit 8
    // bits 9-15: reserved for future metrics
}

// MARK: - Serialization

extension MerkleLeaf {
    /// Serialize to exactly 90 bytes in the canonical big-endian protocol format.
    ///
    /// Layout (authoritative — circuits and verifiers must match exactly):
    /// ```
    /// bytes  0-3:   day_id        (uint32, big-endian)
    /// bytes  4-35:  wallet        (bytes32)
    /// bytes 36-37:  timezone_off  (int16,  big-endian)
    /// bytes 38-41:  steps         (uint32, big-endian)
    /// bytes 42-45:  active_energy (uint32, big-endian)
    /// bytes 46-47:  exercise_mins (uint16, big-endian)
    /// bytes 48-49:  hrv           (uint16, big-endian)
    /// bytes 50-51:  resting_hr    (uint16, big-endian)
    /// bytes 52-53:  sleep_mins    (uint16, big-endian)
    /// bytes 54:     workout_count (uint8)
    /// bytes 55:     source_count  (uint8)
    /// bytes 56-57:  data_flags    (uint16, big-endian)
    /// bytes 58-89:  source_hash   (bytes32)
    /// ```
    /// Total: 90 bytes.
    func serialize() -> Data {
        var data = Data(capacity: 90)

        // bytes 0-3: day_id (uint32 big-endian)
        data.appendUInt32BE(dayId)

        // bytes 4-35: wallet (bytes32, exactly 32 bytes)
        let walletPadded = wallet.count >= 32
            ? wallet.prefix(32)
            : Data(repeating: 0, count: 32 - wallet.count) + wallet
        data.append(contentsOf: walletPadded)

        // bytes 36-37: timezone_offset (int16 big-endian)
        data.appendInt16BE(timezoneOffset)

        // bytes 38-41: steps (uint32 big-endian)
        data.appendUInt32BE(steps)

        // bytes 42-45: active_energy (uint32 big-endian)
        data.appendUInt32BE(activeEnergy)

        // bytes 46-47: exercise_mins (uint16 big-endian)
        data.appendUInt16BE(exerciseMins)

        // bytes 48-49: hrv (uint16 big-endian)
        data.appendUInt16BE(hrv)

        // bytes 50-51: resting_hr (uint16 big-endian)
        data.appendUInt16BE(restingHR)

        // bytes 52-53: sleep_mins (uint16 big-endian)
        data.appendUInt16BE(sleepMins)

        // byte 54: workout_count (uint8)
        data.append(workoutCount)

        // byte 55: source_count (uint8)
        data.append(sourceCount)

        // bytes 56-57: data_flags (uint16 big-endian)
        data.appendUInt16BE(dataFlags)

        // bytes 58-89: source_hash (bytes32, exactly 32 bytes)
        let sourceHashPadded = sourceHash.count >= 32
            ? sourceHash.prefix(32)
            : sourceHash + Data(repeating: 0, count: 32 - sourceHash.count)
        data.append(contentsOf: sourceHashPadded)

        precondition(data.count == 90, "MerkleLeaf serialization must be exactly 90 bytes, got \(data.count)")
        return data
    }

    /// Deserialize from 90 bytes. Returns nil if data is not exactly 90 bytes.
    static func deserialize(from data: Data) -> MerkleLeaf? {
        guard data.count == 90 else { return nil }

        let dayId     = data.readUInt32BE(at: 0)
        let wallet    = data[4..<36]
        let tzOffset  = data.readInt16BE(at: 36)
        let steps     = data.readUInt32BE(at: 38)
        let energy    = data.readUInt32BE(at: 42)
        let exercise  = data.readUInt16BE(at: 46)
        let hrv       = data.readUInt16BE(at: 48)
        let rhr       = data.readUInt16BE(at: 50)
        let sleep     = data.readUInt16BE(at: 52)
        let workouts  = data[54]
        let sources   = data[55]
        let flags     = data.readUInt16BE(at: 56)
        let srcHash   = data[58..<90]

        return MerkleLeaf(
            dayId: dayId,
            wallet: Data(wallet),
            timezoneOffset: tzOffset,
            steps: steps,
            activeEnergy: energy,
            exerciseMins: exercise,
            hrv: hrv,
            restingHR: rhr,
            sleepMins: sleep,
            workoutCount: workouts,
            sourceCount: sources,
            dataFlags: flags,
            sourceHash: Data(srcHash)
        )
    }
}

// MARK: - Equatable & Hashable

extension MerkleLeaf: Equatable {
    static func == (lhs: MerkleLeaf, rhs: MerkleLeaf) -> Bool {
        lhs.serialize() == rhs.serialize()
    }
}

extension MerkleLeaf: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(serialize())
    }
}

// MARK: - Day ID Helpers

extension MerkleLeaf {
    /// The epoch date used for day_id computation: 2024-01-01 UTC.
    static let epochDate: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
    }()

    /// Compute the day_id for a given date in the given timezone.
    /// Day_id = number of calendar days from 2024-01-01 (in the local timezone) to the given date.
    static func dayId(for date: Date, in timezone: TimeZone) -> UInt32 {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        let components = cal.dateComponents([.day], from: epochDate, to: date)
        let days = max(0, components.day ?? 0)
        return UInt32(days)
    }

    /// Compute the calendar date for a given day_id in the given timezone.
    static func date(for dayId: UInt32, in timezone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        return cal.date(byAdding: .day, value: Int(dayId), to: epochDate)!
    }
}

// MARK: - Data Flags Builder

struct MerkleLeafFlagsBuilder {
    private var flags: UInt16 = 0

    mutating func set(_ flag: MerkleLeafFlag, if condition: Bool) {
        if condition { flags |= flag.rawValue }
    }

    func build() -> UInt16 { flags }
}

/// Compute dataFlags from normalized metric values.
/// Pass `hrvPresent` and `restingHRPresent` separately since 0 means absent.
func computeDataFlags(
    steps: UInt32,
    activeEnergy: UInt32,
    exerciseMins: UInt16,
    hrvPresent: Bool,
    restingHRPresent: Bool,
    sleepMins: UInt16,
    workoutCount: UInt8,
    bloodOxygenPresent: Bool,
    sourceCount: UInt8
) -> UInt16 {
    var builder = MerkleLeafFlagsBuilder()
    builder.set(.stepsPresent,        if: steps > 0)
    builder.set(.activeEnergyPresent, if: activeEnergy > 0)
    builder.set(.exerciseMinsPresent, if: exerciseMins > 0)
    builder.set(.hrvPresent,          if: hrvPresent)
    builder.set(.restingHRPresent,    if: restingHRPresent)
    builder.set(.sleepPresent,        if: sleepMins > 0)
    builder.set(.workoutLogged,       if: workoutCount > 0)
    builder.set(.bloodOxygenPresent,  if: bloodOxygenPresent)
    builder.set(.multiSourceDay,      if: sourceCount > 1)
    return builder.build()
}

// MARK: - Source Hash

/// Compute the source hash for a set of source bundle IDs.
/// Sort alphabetically, concatenate as UTF-8, SHA256.
func computeSourceHash(sourceBundleIDs: [String]) -> Data {
    let sorted = sourceBundleIDs.sorted()
    let concatenated = sorted.joined()
    guard let bytes = concatenated.data(using: .utf8) else {
        return Data(repeating: 0, count: 32)
    }
    let digest = SHA256.hash(data: bytes)
    return Data(digest)
}

// MARK: - Data Serialization Helpers (private)

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8)  & 0xFF))
        append(UInt8( value        & 0xFF))
    }

    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8( value       & 0xFF))
    }

    mutating func appendInt16BE(_ value: Int16) {
        let bits = UInt16(bitPattern: value)
        appendUInt16BE(bits)
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1])
        return (b0 << 8) | b1
    }

    func readInt16BE(at offset: Int) -> Int16 {
        return Int16(bitPattern: readUInt16BE(at: offset))
    }
}
