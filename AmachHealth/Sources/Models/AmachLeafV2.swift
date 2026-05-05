// AmachLeafV2.swift
// AmachHealth
//
// Xcode: keep OUT of the iOS app target (shared spec for off-device proving / circom).
//
// PROTOCOL SPEC v2.0 — May 2026 (Spring Push Season One)
//
// The v2 leaf is the data layer foundation of the Amach verification factory
// (see VERIFICATION_FACTORY.md). It expands v1's 90-byte daily summary to 124
// bytes by adding a self-describing envelope (version, leafType, schemaVersion,
// reserved_envelope), VO2 max, body composition, sleep stage breakdown, and
// reserved payload capacity for future schema bumps without changing the hash
// structure.
//
// Hashing: Poseidon4 over four 31-byte chunks (124 = 4 * 31, no padding).
// Wire format: 124 bytes, big-endian, fixed field order.
//
// This spec is authoritative. Circuits, JS hashing helpers, and any future
// language bindings must reproduce it exactly. Cross-platform consistency is
// asserted in AmachLeafV2Tests via fixed hash vectors that match the JS impl
// in zk/scripts/hash_leaf.js.

import Foundation

// MARK: - Envelope Constants

/// Constants for the v2 envelope. Anything other than these values is rejected
/// by the validator. v3 will introduce new leafType values; v2.1 will bump
/// schemaVersion.
enum AmachLeafV2Envelope {
    static let version: UInt8 = 0x02
    /// 0x00 = daily_summary. Other leaf types arrive in v3.
    static let leafTypeDailySummary: UInt8 = 0x00
    /// v2.0 daily_summary uses schema 0x01. Bumps as new fields fill the
    /// reserved_payload bytes (80-91).
    static let schemaVersionDailySummary: UInt8 = 0x01
}

// MARK: - AmachLeafV2

/// One day of normalized health data in the v2 wire format. The unit of
/// commitment in the Merkle tree for Spring Push Season One and beyond.
///
/// Naming follows the verification factory's generic-over-specific rule:
/// AmachLeafV2 (not DailyHealthLeafV2) so v3 can introduce non-daily-summary
/// leaf types under the same name umbrella.
struct AmachLeafV2 {
    // ── Envelope (bytes 0-3) ──────────────────────────────
    /// Always 0x02 for v2 leaves.
    let version: UInt8
    /// 0x00 = daily summary. Future leaf types extend here.
    let leafType: UInt8
    /// Per-leafType schema version. 0x01 for v2.0 daily_summary.
    let schemaVersion: UInt8
    /// Reserved envelope byte. Must be 0 in v2.0; future minor bumps may use it.
    let reservedEnvelope: UInt8

    // ── Identity & time (bytes 4-41) ──────────────────────
    let wallet: Data            // bytes 4-35 (32 bytes)
    let dayId: UInt32           // bytes 36-39
    let timezoneOffset: Int16   // bytes 40-41 (minutes from UTC)

    // ── v1-equivalent metrics (bytes 42-63) ───────────────
    let steps: UInt32           // bytes 42-45
    let activeEnergy: UInt32    // bytes 46-49 (kcal * 100)
    let exerciseMins: UInt16    // bytes 50-51
    let hrv: UInt16             // bytes 52-53 (ms * 10, 0 if absent)
    let restingHR: UInt16       // bytes 54-55 (bpm * 10, 0 if absent)
    let sleepMins: UInt16       // bytes 56-57 (total sleep)
    let workoutCount: UInt8     // byte 58
    let sourceCount: UInt8      // byte 59
    let dataFlags: UInt32       // bytes 60-63 (expanded from u16 in v1)

    // ── New v2 metrics (bytes 64-79) ──────────────────────
    let vo2max: UInt16          // bytes 64-65 (vo2max * 10, 0 if absent)
    let weight: UInt16          // bytes 66-67 (grams / 10, 0 if absent; range 0..655.35 kg)
    let bodyFatPct: UInt16      // bytes 68-69 (percent * 100, 0 if absent)
    let leanMass: UInt16        // bytes 70-71 (grams / 10, 0 if absent)
    let deepSleepMins: UInt16   // bytes 72-73
    let remSleepMins: UInt16    // bytes 74-75
    let lightSleepMins: UInt16  // bytes 76-77
    let awakeMins: UInt16       // bytes 78-79

    // ── Reserved & source binding (bytes 80-123) ──────────
    /// Exactly 12 bytes of zero in v2.0. v2.1+ schema bumps populate this in
    /// place without changing the Poseidon4 chunking.
    let reservedPayload: Data   // bytes 80-91 (12 bytes)
    let sourceHash: Data        // bytes 92-123 (32 bytes, SHA256 of sorted bundle IDs)

    static let serializedByteCount: Int = 124
    static let chunkByteCount: Int = 31
    static let chunkCount: Int = 4
}

// MARK: - Expanded Data Flags

/// v2 keeps the same low-bit semantics as v1 (so a v2 leaf's flag bits can be
/// read with v1 semantics by readers that only care about the legacy metrics)
/// and adds new bits for the v2-specific metrics. dataFlags grows from u16 to
/// u32 to reserve plenty of room for future presence indicators.
enum AmachLeafV2Flag: UInt32 {
    // bits 0-8: identical to v1 (MerkleLeafFlag) for readability across versions
    case stepsPresent        = 0x0000_0001  // bit 0
    case activeEnergyPresent = 0x0000_0002  // bit 1
    case exerciseMinsPresent = 0x0000_0004  // bit 2
    case hrvPresent          = 0x0000_0008  // bit 3
    case restingHRPresent    = 0x0000_0010  // bit 4
    case sleepPresent        = 0x0000_0020  // bit 5
    case workoutLogged       = 0x0000_0040  // bit 6
    case bloodOxygenPresent  = 0x0000_0080  // bit 7
    case multiSourceDay      = 0x0000_0100  // bit 8

    // bits 9-15: reserved for v1-era expansion (kept zero for compat)

    // bits 16+: v2-specific presence flags
    case vo2maxPresent       = 0x0001_0000  // bit 16
    case weightPresent       = 0x0002_0000  // bit 17
    case bodyFatPctPresent   = 0x0004_0000  // bit 18
    case leanMassPresent     = 0x0008_0000  // bit 19
    case deepSleepPresent    = 0x0010_0000  // bit 20
    case remSleepPresent     = 0x0020_0000  // bit 21
    case lightSleepPresent   = 0x0040_0000  // bit 22
    case awakeMinsPresent    = 0x0080_0000  // bit 23
}

// MARK: - Validation

extension AmachLeafV2 {
    enum ValidationError: Error, Equatable, CustomStringConvertible {
        case wrongVersion(UInt8)
        case wrongLeafType(UInt8)
        case wrongSchemaVersion(UInt8)
        case nonZeroReservedEnvelope(UInt8)
        case nonZeroReservedPayload
        case walletWrongLength(Int)
        case sourceHashWrongLength(Int)
        case reservedPayloadWrongLength(Int)

        var description: String {
            switch self {
            case .wrongVersion(let v):
                return "AmachLeafV2: version must be 0x02, got 0x\(String(v, radix: 16))"
            case .wrongLeafType(let t):
                return "AmachLeafV2: leafType must be 0x00 (daily_summary), got 0x\(String(t, radix: 16))"
            case .wrongSchemaVersion(let s):
                return "AmachLeafV2: schemaVersion must be 0x01, got 0x\(String(s, radix: 16))"
            case .nonZeroReservedEnvelope(let r):
                return "AmachLeafV2: reservedEnvelope must be 0 in v2.0, got 0x\(String(r, radix: 16))"
            case .nonZeroReservedPayload:
                return "AmachLeafV2: reservedPayload must be all-zero in v2.0"
            case .walletWrongLength(let n):
                return "AmachLeafV2: wallet must be 32 bytes, got \(n)"
            case .sourceHashWrongLength(let n):
                return "AmachLeafV2: sourceHash must be 32 bytes, got \(n)"
            case .reservedPayloadWrongLength(let n):
                return "AmachLeafV2: reservedPayload must be 12 bytes, got \(n)"
            }
        }
    }

    /// Throws if any envelope or fixed-size field violates the v2.0 daily_summary
    /// contract. Use after deserialize, after construction from external
    /// inputs, and before hashing.
    func validate() throws {
        if version != AmachLeafV2Envelope.version {
            throw ValidationError.wrongVersion(version)
        }
        if leafType != AmachLeafV2Envelope.leafTypeDailySummary {
            throw ValidationError.wrongLeafType(leafType)
        }
        if schemaVersion != AmachLeafV2Envelope.schemaVersionDailySummary {
            throw ValidationError.wrongSchemaVersion(schemaVersion)
        }
        if reservedEnvelope != 0 {
            throw ValidationError.nonZeroReservedEnvelope(reservedEnvelope)
        }
        if wallet.count != 32 {
            throw ValidationError.walletWrongLength(wallet.count)
        }
        if sourceHash.count != 32 {
            throw ValidationError.sourceHashWrongLength(sourceHash.count)
        }
        if reservedPayload.count != 12 {
            throw ValidationError.reservedPayloadWrongLength(reservedPayload.count)
        }
        if reservedPayload.contains(where: { $0 != 0 }) {
            throw ValidationError.nonZeroReservedPayload
        }
    }
}

// MARK: - Convenience Init

extension AmachLeafV2 {
    /// Builder that defaults all envelope fields to the v2.0 daily_summary
    /// contract. Reduces the chance of an envelope mismatch at call sites that
    /// only care about the metric payload.
    init(
        wallet: Data,
        dayId: UInt32,
        timezoneOffset: Int16,
        steps: UInt32,
        activeEnergy: UInt32,
        exerciseMins: UInt16,
        hrv: UInt16,
        restingHR: UInt16,
        sleepMins: UInt16,
        workoutCount: UInt8,
        sourceCount: UInt8,
        dataFlags: UInt32,
        vo2max: UInt16 = 0,
        weight: UInt16 = 0,
        bodyFatPct: UInt16 = 0,
        leanMass: UInt16 = 0,
        deepSleepMins: UInt16 = 0,
        remSleepMins: UInt16 = 0,
        lightSleepMins: UInt16 = 0,
        awakeMins: UInt16 = 0,
        sourceHash: Data
    ) {
        self.version = AmachLeafV2Envelope.version
        self.leafType = AmachLeafV2Envelope.leafTypeDailySummary
        self.schemaVersion = AmachLeafV2Envelope.schemaVersionDailySummary
        self.reservedEnvelope = 0
        self.wallet = wallet
        self.dayId = dayId
        self.timezoneOffset = timezoneOffset
        self.steps = steps
        self.activeEnergy = activeEnergy
        self.exerciseMins = exerciseMins
        self.hrv = hrv
        self.restingHR = restingHR
        self.sleepMins = sleepMins
        self.workoutCount = workoutCount
        self.sourceCount = sourceCount
        self.dataFlags = dataFlags
        self.vo2max = vo2max
        self.weight = weight
        self.bodyFatPct = bodyFatPct
        self.leanMass = leanMass
        self.deepSleepMins = deepSleepMins
        self.remSleepMins = remSleepMins
        self.lightSleepMins = lightSleepMins
        self.awakeMins = awakeMins
        self.reservedPayload = Data(repeating: 0, count: 12)
        self.sourceHash = sourceHash
    }
}

// MARK: - Serialization

extension AmachLeafV2 {
    /// Serialize to exactly 124 bytes in canonical big-endian form.
    ///
    /// Layout (authoritative — circuits and verifiers must match exactly):
    /// ```
    /// byte    0:     version            (uint8)
    /// byte    1:     leaf_type          (uint8)
    /// byte    2:     schema_version     (uint8)
    /// byte    3:     reserved_envelope  (uint8)
    /// bytes   4-35:  wallet             (bytes32)
    /// bytes  36-39:  day_id             (uint32 BE)
    /// bytes  40-41:  timezone_offset    (int16 BE)
    /// bytes  42-45:  steps              (uint32 BE)
    /// bytes  46-49:  active_energy      (uint32 BE)
    /// bytes  50-51:  exercise_mins      (uint16 BE)
    /// bytes  52-53:  hrv                (uint16 BE)
    /// bytes  54-55:  resting_hr         (uint16 BE)
    /// bytes  56-57:  sleep_mins         (uint16 BE)
    /// byte   58:     workout_count      (uint8)
    /// byte   59:     source_count       (uint8)
    /// bytes  60-63:  data_flags         (uint32 BE)
    /// bytes  64-65:  vo2max             (uint16 BE)
    /// bytes  66-67:  weight             (uint16 BE)
    /// bytes  68-69:  body_fat_pct       (uint16 BE)
    /// bytes  70-71:  lean_mass          (uint16 BE)
    /// bytes  72-73:  deep_sleep_mins    (uint16 BE)
    /// bytes  74-75:  rem_sleep_mins     (uint16 BE)
    /// bytes  76-77:  light_sleep_mins   (uint16 BE)
    /// bytes  78-79:  awake_mins         (uint16 BE)
    /// bytes  80-91:  reserved_payload   (bytes12, all zero in v2.0)
    /// bytes  92-123: source_hash        (bytes32)
    /// ```
    /// Total: 124 bytes.
    func serialize() -> Data {
        var data = Data(capacity: AmachLeafV2.serializedByteCount)

        // bytes 0-3: envelope
        data.append(version)
        data.append(leafType)
        data.append(schemaVersion)
        data.append(reservedEnvelope)

        // bytes 4-35: wallet (left-pad if shorter, truncate if longer)
        let walletPadded: Data
        if wallet.count >= 32 {
            walletPadded = wallet.prefix(32)
        } else {
            walletPadded = Data(repeating: 0, count: 32 - wallet.count) + wallet
        }
        data.append(contentsOf: walletPadded)

        // bytes 36-39: day_id
        data.appendV2UInt32BE(dayId)
        // bytes 40-41: timezone_offset
        data.appendV2Int16BE(timezoneOffset)
        // bytes 42-45: steps
        data.appendV2UInt32BE(steps)
        // bytes 46-49: active_energy
        data.appendV2UInt32BE(activeEnergy)
        // bytes 50-51: exercise_mins
        data.appendV2UInt16BE(exerciseMins)
        // bytes 52-53: hrv
        data.appendV2UInt16BE(hrv)
        // bytes 54-55: resting_hr
        data.appendV2UInt16BE(restingHR)
        // bytes 56-57: sleep_mins
        data.appendV2UInt16BE(sleepMins)

        // byte 58: workout_count
        data.append(workoutCount)
        // byte 59: source_count
        data.append(sourceCount)

        // bytes 60-63: data_flags (u32, expanded from v1's u16)
        data.appendV2UInt32BE(dataFlags)

        // bytes 64-79: v2 payload
        data.appendV2UInt16BE(vo2max)
        data.appendV2UInt16BE(weight)
        data.appendV2UInt16BE(bodyFatPct)
        data.appendV2UInt16BE(leanMass)
        data.appendV2UInt16BE(deepSleepMins)
        data.appendV2UInt16BE(remSleepMins)
        data.appendV2UInt16BE(lightSleepMins)
        data.appendV2UInt16BE(awakeMins)

        // bytes 80-91: reserved_payload (12 bytes — v2.0 must be zero, but we
        // serialize whatever is held so a malformed leaf still round-trips for
        // diagnostic purposes; callers should validate() first).
        let reservedPadded: Data
        if reservedPayload.count >= 12 {
            reservedPadded = reservedPayload.prefix(12)
        } else {
            reservedPadded = reservedPayload + Data(repeating: 0, count: 12 - reservedPayload.count)
        }
        data.append(contentsOf: reservedPadded)

        // bytes 92-123: source_hash (right-pad with zeros if shorter, truncate if longer)
        let sourceHashPadded: Data
        if sourceHash.count >= 32 {
            sourceHashPadded = sourceHash.prefix(32)
        } else {
            sourceHashPadded = sourceHash + Data(repeating: 0, count: 32 - sourceHash.count)
        }
        data.append(contentsOf: sourceHashPadded)

        precondition(
            data.count == AmachLeafV2.serializedByteCount,
            "AmachLeafV2 serialization must be exactly 124 bytes, got \(data.count)"
        )
        return data
    }

    /// Deserialize from exactly 124 bytes. Returns nil for any other length.
    /// Does NOT validate envelope semantics — call validate() to assert.
    static func deserialize(from data: Data) -> AmachLeafV2? {
        guard data.count == AmachLeafV2.serializedByteCount else { return nil }
        let base = data.startIndex

        let version          = data[base + 0]
        let leafType         = data[base + 1]
        let schemaVersion    = data[base + 2]
        let reservedEnvelope = data[base + 3]
        let wallet           = data.subdata(in: (base + 4)..<(base + 36))
        let dayId            = data.readV2UInt32BE(at: base + 36)
        let tzOffset         = data.readV2Int16BE(at: base + 40)
        let steps            = data.readV2UInt32BE(at: base + 42)
        let activeEnergy     = data.readV2UInt32BE(at: base + 46)
        let exerciseMins     = data.readV2UInt16BE(at: base + 50)
        let hrv              = data.readV2UInt16BE(at: base + 52)
        let restingHR        = data.readV2UInt16BE(at: base + 54)
        let sleepMins        = data.readV2UInt16BE(at: base + 56)
        let workoutCount     = data[base + 58]
        let sourceCount      = data[base + 59]
        let dataFlags        = data.readV2UInt32BE(at: base + 60)
        let vo2max           = data.readV2UInt16BE(at: base + 64)
        let weight           = data.readV2UInt16BE(at: base + 66)
        let bodyFatPct       = data.readV2UInt16BE(at: base + 68)
        let leanMass         = data.readV2UInt16BE(at: base + 70)
        let deepSleepMins    = data.readV2UInt16BE(at: base + 72)
        let remSleepMins     = data.readV2UInt16BE(at: base + 74)
        let lightSleepMins   = data.readV2UInt16BE(at: base + 76)
        let awakeMins        = data.readV2UInt16BE(at: base + 78)
        let reservedPayload  = data.subdata(in: (base + 80)..<(base + 92))
        let sourceHash       = data.subdata(in: (base + 92)..<(base + 124))

        return AmachLeafV2(
            version: version,
            leafType: leafType,
            schemaVersion: schemaVersion,
            reservedEnvelope: reservedEnvelope,
            wallet: wallet,
            dayId: dayId,
            timezoneOffset: tzOffset,
            steps: steps,
            activeEnergy: activeEnergy,
            exerciseMins: exerciseMins,
            hrv: hrv,
            restingHR: restingHR,
            sleepMins: sleepMins,
            workoutCount: workoutCount,
            sourceCount: sourceCount,
            dataFlags: dataFlags,
            vo2max: vo2max,
            weight: weight,
            bodyFatPct: bodyFatPct,
            leanMass: leanMass,
            deepSleepMins: deepSleepMins,
            remSleepMins: remSleepMins,
            lightSleepMins: lightSleepMins,
            awakeMins: awakeMins,
            reservedPayload: reservedPayload,
            sourceHash: sourceHash
        )
    }
}

// MARK: - Poseidon4 Chunking

/// Decomposed leaf bytes ready for Poseidon4. Each chunk is a big-endian
/// integer over 31 bytes; 4 * 31 == 124 so no padding is required (which is
/// the load-bearing reason the v2 schema was sized at 124 bytes exactly).
struct AmachLeafV2Chunks: Equatable {
    /// Big-endian uint248 from bytes 0-30.
    let chunk1: Data
    /// Big-endian uint248 from bytes 31-61.
    let chunk2: Data
    /// Big-endian uint248 from bytes 62-92.
    let chunk3: Data
    /// Big-endian uint248 from bytes 93-123.
    let chunk4: Data

    /// Each chunk as a hex-encoded big-endian integer string (no 0x prefix,
    /// up to 62 chars). This form is what hash_leaf.js consumes: BigInt('0x' + hex).
    var asHexStrings: [String] {
        [chunk1, chunk2, chunk3, chunk4].map { d in
            d.map { String(format: "%02x", $0) }.joined()
        }
    }
}

extension AmachLeafV2 {
    /// Split serialized bytes into the four 31-byte chunks Poseidon4 consumes.
    /// Mirrors hash_leaf.js's hashLeafV2 chunking exactly.
    static func chunks(from serialized: Data) -> AmachLeafV2Chunks? {
        guard serialized.count == AmachLeafV2.serializedByteCount else { return nil }
        let s = serialized.startIndex
        return AmachLeafV2Chunks(
            chunk1: serialized.subdata(in: (s +  0)..<(s + 31)),
            chunk2: serialized.subdata(in: (s + 31)..<(s + 62)),
            chunk3: serialized.subdata(in: (s + 62)..<(s + 93)),
            chunk4: serialized.subdata(in: (s + 93)..<(s + 124))
        )
    }

    /// Convenience: chunks for self.serialize().
    func chunks() -> AmachLeafV2Chunks {
        // serialize() always produces 124 bytes by precondition, so chunks is
        // guaranteed non-nil.
        return AmachLeafV2.chunks(from: serialize())!
    }
}

// MARK: - Equatable & Hashable

extension AmachLeafV2: Equatable {
    static func == (lhs: AmachLeafV2, rhs: AmachLeafV2) -> Bool {
        lhs.serialize() == rhs.serialize()
    }
}

extension AmachLeafV2: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(serialize())
    }
}

// MARK: - Day ID helper bridge

extension AmachLeafV2 {
    /// v2 reuses the same day-id epoch (2024-01-01) and computation as v1 so a
    /// participant's day-id sequence remains stable across the migration.
    static func dayId(for date: Date, in timezone: TimeZone) -> UInt32 {
        MerkleLeaf.dayId(for: date, in: timezone)
    }

    static func date(for dayId: UInt32, in timezone: TimeZone) -> Date {
        MerkleLeaf.date(for: dayId, in: timezone)
    }
}

// MARK: - Serialization helpers (private, namespaced to avoid v1 collisions)

private extension Data {
    mutating func appendV2UInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8)  & 0xFF))
        append(UInt8( value        & 0xFF))
    }

    mutating func appendV2UInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8( value       & 0xFF))
    }

    mutating func appendV2Int16BE(_ value: Int16) {
        appendV2UInt16BE(UInt16(bitPattern: value))
    }

    func readV2UInt32BE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    func readV2UInt16BE(at offset: Int) -> UInt16 {
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1])
        return (b0 << 8) | b1
    }

    func readV2Int16BE(at offset: Int) -> Int16 {
        Int16(bitPattern: readV2UInt16BE(at: offset))
    }
}
