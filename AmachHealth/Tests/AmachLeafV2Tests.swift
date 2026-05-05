// AmachLeafV2Tests.swift
// AmachHealth
//
// XCTest coverage for the v2 leaf format. Layer 0 acceptance criteria:
//
//   1. Round-trip: struct -> 124 bytes -> struct preserves all fields.
//   2. Validation: rejects wrong version / leafType / schemaVersion / non-zero
//      reserved bytes / wrong wallet or sourceHash length.
//   3. Cross-platform hash vectors: five fixed leaves whose serialized hex
//      and Poseidon4 hash match the JS implementation exactly. The hashes
//      below are pinned against the output of zk/scripts/__tests__/v2_test_vectors.js
//      and are also asserted by hash_leaf.test.js (Jest) — drift on either
//      side breaks the cross-platform consistency check.
//
// Run with: swift test --filter AmachLeafV2Tests

import XCTest
@testable import AmachHealth
import Foundation

final class AmachLeafV2Tests: XCTestCase {

    // MARK: - Serialization shape

    func testSerializationLength() {
        let leaf = makeDefaultLeaf()
        let bytes = leaf.serialize()
        XCTAssertEqual(bytes.count, 124, "Serialized v2 leaf must be exactly 124 bytes")
        XCTAssertEqual(AmachLeafV2.serializedByteCount, 124)
    }

    func testEnvelopeBytePositions() {
        let leaf = makeDefaultLeaf()
        let bytes = leaf.serialize()
        XCTAssertEqual(bytes[0], 0x02, "byte 0 must be version 0x02")
        XCTAssertEqual(bytes[1], 0x00, "byte 1 must be leafType 0x00 (daily_summary)")
        XCTAssertEqual(bytes[2], 0x01, "byte 2 must be schemaVersion 0x01")
        XCTAssertEqual(bytes[3], 0x00, "byte 3 must be reservedEnvelope 0x00 in v2.0")
    }

    func testReservedPayloadBytesAreZero() {
        let leaf = makeDefaultLeaf()
        let bytes = leaf.serialize()
        // bytes 80..91 are the 12-byte reserved_payload region
        for i in 80..<92 {
            XCTAssertEqual(bytes[i], 0x00, "reserved_payload byte \(i) must be 0 in v2.0")
        }
    }

    func testKnownByteOffsets() {
        // Build a leaf with distinct values per field to verify byte placement.
        let leaf = AmachLeafV2(
            wallet: Data(repeating: 0xAB, count: 32),
            dayId: 0x0000_0064,         // 100
            timezoneOffset: -300,        // 0xFED4
            steps: 0x0000_1F40,          // 8000
            activeEnergy: 0x0000_8902,   // 35074
            exerciseMins: 45,            // 0x002D
            hrv: 423,
            restingHR: 580,
            sleepMins: 420,
            workoutCount: 1,
            sourceCount: 2,
            dataFlags: 0x0001_017F,      // u32 mid-range pattern
            vo2max: 425,
            weight: 7800,
            bodyFatPct: 1850,
            leanMass: 6300,
            deepSleepMins: 75,
            remSleepMins: 95,
            lightSleepMins: 240,
            awakeMins: 20,
            sourceHash: Data(repeating: 0xCC, count: 32)
        )
        let b = leaf.serialize()

        // wallet at 4-35
        XCTAssertTrue(b[4..<36].allSatisfy { $0 == 0xAB })
        // dayId at 36-39 (big-endian)
        XCTAssertEqual([b[36], b[37], b[38], b[39]], [0x00, 0x00, 0x00, 0x64])
        // tz_offset at 40-41 (-300 -> 0xFED4)
        XCTAssertEqual([b[40], b[41]], [0xFE, 0xD4])
        // steps at 42-45
        XCTAssertEqual([b[42], b[43], b[44], b[45]], [0x00, 0x00, 0x1F, 0x40])
        // workout_count at 58, source_count at 59
        XCTAssertEqual(b[58], 0x01)
        XCTAssertEqual(b[59], 0x02)
        // dataFlags at 60-63 (u32)
        XCTAssertEqual([b[60], b[61], b[62], b[63]], [0x00, 0x01, 0x01, 0x7F])
        // vo2max at 64-65 (425 = 0x01A9)
        XCTAssertEqual([b[64], b[65]], [0x01, 0xA9])
        // sourceHash at 92-123
        XCTAssertTrue(b[92..<124].allSatisfy { $0 == 0xCC })
    }

    // MARK: - Round-trip

    func testRoundTripDefault() {
        let leaf = makeDefaultLeaf()
        let bytes = leaf.serialize()
        guard let recovered = AmachLeafV2.deserialize(from: bytes) else {
            return XCTFail("deserialize returned nil")
        }
        XCTAssertEqual(leaf, recovered)
        XCTAssertEqual(bytes, recovered.serialize(), "second-round serialization must match first")
    }

    func testRoundTripAllZeroEnvelope() {
        // envelope-only fixture from v2_test_vectors.js
        let leaf = AmachLeafV2(
            wallet: Data(repeating: 0, count: 32),
            dayId: 0,
            timezoneOffset: 0,
            steps: 0,
            activeEnergy: 0,
            exerciseMins: 0,
            hrv: 0,
            restingHR: 0,
            sleepMins: 0,
            workoutCount: 0,
            sourceCount: 0,
            dataFlags: 0,
            vo2max: 0,
            weight: 0,
            bodyFatPct: 0,
            leanMass: 0,
            deepSleepMins: 0,
            remSleepMins: 0,
            lightSleepMins: 0,
            awakeMins: 0,
            sourceHash: Data(repeating: 0, count: 32)
        )
        let bytes = leaf.serialize()
        XCTAssertEqual(bytes.count, 124)
        // First 4 bytes are envelope (0x02 0x00 0x01 0x00); the rest must be zero.
        XCTAssertEqual([bytes[0], bytes[1], bytes[2], bytes[3]], [0x02, 0x00, 0x01, 0x00])
        XCTAssertTrue(bytes[4..<124].allSatisfy { $0 == 0 })
        XCTAssertEqual(AmachLeafV2.deserialize(from: bytes), leaf)
    }

    func testRoundTripMaxFields() {
        let leaf = AmachLeafV2(
            wallet: Data(repeating: 0xFF, count: 32),
            dayId: UInt32.max,
            timezoneOffset: Int16.max,
            steps: UInt32.max,
            activeEnergy: UInt32.max,
            exerciseMins: UInt16.max,
            hrv: UInt16.max,
            restingHR: UInt16.max,
            sleepMins: UInt16.max,
            workoutCount: UInt8.max,
            sourceCount: UInt8.max,
            dataFlags: UInt32.max,
            vo2max: UInt16.max,
            weight: UInt16.max,
            bodyFatPct: UInt16.max,
            leanMass: UInt16.max,
            deepSleepMins: UInt16.max,
            remSleepMins: UInt16.max,
            lightSleepMins: UInt16.max,
            awakeMins: UInt16.max,
            sourceHash: Data(repeating: 0xFF, count: 32)
        )
        guard let recovered = AmachLeafV2.deserialize(from: leaf.serialize()) else {
            return XCTFail("deserialize nil at max fields")
        }
        XCTAssertEqual(leaf, recovered)
    }

    func testDeserializeRejectsWrongLength() {
        XCTAssertNil(AmachLeafV2.deserialize(from: Data(repeating: 0, count: 90)))
        XCTAssertNil(AmachLeafV2.deserialize(from: Data(repeating: 0, count: 123)))
        XCTAssertNil(AmachLeafV2.deserialize(from: Data(repeating: 0, count: 125)))
        XCTAssertNil(AmachLeafV2.deserialize(from: Data()))
    }

    // MARK: - Validation

    func testValidateAcceptsConformantLeaf() {
        XCTAssertNoThrow(try makeDefaultLeaf().validate())
    }

    func testValidateRejectsWrongVersion() {
        let leaf = makeDefaultLeaf().withRawEnvelope(version: 0x01)
        XCTAssertThrowsError(try leaf.validate()) { err in
            XCTAssertEqual(err as? AmachLeafV2.ValidationError, .wrongVersion(0x01))
        }
    }

    func testValidateRejectsWrongLeafType() {
        let leaf = makeDefaultLeaf().withRawEnvelope(leafType: 0x05)
        XCTAssertThrowsError(try leaf.validate()) { err in
            XCTAssertEqual(err as? AmachLeafV2.ValidationError, .wrongLeafType(0x05))
        }
    }

    func testValidateRejectsWrongSchemaVersion() {
        let leaf = makeDefaultLeaf().withRawEnvelope(schemaVersion: 0x02)
        XCTAssertThrowsError(try leaf.validate()) { err in
            XCTAssertEqual(err as? AmachLeafV2.ValidationError, .wrongSchemaVersion(0x02))
        }
    }

    func testValidateRejectsNonZeroReservedEnvelope() {
        let leaf = makeDefaultLeaf().withRawEnvelope(reservedEnvelope: 0xFF)
        XCTAssertThrowsError(try leaf.validate()) { err in
            XCTAssertEqual(err as? AmachLeafV2.ValidationError, .nonZeroReservedEnvelope(0xFF))
        }
    }

    func testValidateRejectsNonZeroReservedPayload() {
        let leaf = makeDefaultLeaf().withReservedPayload(Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertThrowsError(try leaf.validate()) { err in
            XCTAssertEqual(err as? AmachLeafV2.ValidationError, .nonZeroReservedPayload)
        }
    }

    func testValidateRejectsWalletWrongLength() {
        let leaf = makeDefaultLeaf().withWallet(Data(repeating: 0xAA, count: 31))
        XCTAssertThrowsError(try leaf.validate()) { err in
            XCTAssertEqual(err as? AmachLeafV2.ValidationError, .walletWrongLength(31))
        }
    }

    func testValidateRejectsSourceHashWrongLength() {
        let leaf = makeDefaultLeaf().withSourceHash(Data(repeating: 0xCC, count: 16))
        XCTAssertThrowsError(try leaf.validate()) { err in
            XCTAssertEqual(err as? AmachLeafV2.ValidationError, .sourceHashWrongLength(16))
        }
    }

    // MARK: - Chunking

    func testChunkingProducesFour31ByteChunks() {
        let chunks = makeDefaultLeaf().chunks()
        XCTAssertEqual(chunks.chunk1.count, 31)
        XCTAssertEqual(chunks.chunk2.count, 31)
        XCTAssertEqual(chunks.chunk3.count, 31)
        XCTAssertEqual(chunks.chunk4.count, 31)
        XCTAssertEqual(chunks.chunk1.count + chunks.chunk2.count + chunks.chunk3.count + chunks.chunk4.count, 124)
    }

    // MARK: - Cross-platform Hash Vectors
    //
    // These five vectors (name, serializedHex, expectedHashDec) match the
    // output of zk/scripts/__tests__/v2_test_vectors.js. Both the JS Jest
    // tests and these XCTest cases assert the same expected hashes against
    // the same byte inputs; if either side drifts, the cross-platform
    // consistency property breaks.
    //
    // Update protocol: when changing the v2 schema, regenerate via
    //   node zk/scripts/__tests__/v2_test_vectors.js
    // and refresh both the Swift mirror below and the JS module.

    struct V2Fixture {
        let name: String
        let hex: String
        let expectedHashDec: String
    }

    static let crossPlatformFixtures: [V2Fixture] = [
        V2Fixture(
            name: "zeros_envelope_only",
            hex: "02000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
            expectedHashDec: "21403313304358454773736113173224357181333998349366063546584328596398062212339"
        ),
        V2Fixture(
            name: "default_mid_range",
            hex: "02000100abababababababababababababababababababababababababababababababab0000002afed400002134000088b8003c019c023001c20203000f03ff01a91e78073a189c004b005f00f00014000000000000000000000000cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            expectedHashDec: "18725532646486479229680827961653568949006776413866252906274597062145598179461"
        ),
        V2Fixture(
            name: "all_max",
            hex: "02000100ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            expectedHashDec: "19441507671370079456103933714237196639544633520774316607225291899358709095750"
        ),
        V2Fixture(
            name: "elite_athlete",
            hex: "020001001111111111111111111111111111111111111111111111111111111111111111000001c7fe200000379d00016954005f035601a401e00202000f03ff02641cb6049c1950006e006900f50014000000000000000000000000aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899",
            expectedHashDec: "15052283446839198498298181032097060147164703321831257498670942882713705063055"
        ),
        V2Fixture(
            name: "sedentary_minimal",
            hex: "0200010000000000000000000000000000000000000000000000000000000000000000ab000000640000000004b0000011940000000002d001680001000000210000200800000000001e0032010400140000000000000000000000001111111111111111111111111111111111111111111111111111111111111111",
            expectedHashDec: "21511032248427965295405135826877810908705843958975997094206497487671307315323"
        )
    ]

    func testCrossPlatformVectorsRoundTripExactly() {
        for fx in Self.crossPlatformFixtures {
            guard let bytes = Data(hexString: fx.hex) else {
                return XCTFail("\(fx.name): hex decode failed")
            }
            XCTAssertEqual(bytes.count, 124, "\(fx.name): must decode to 124 bytes")

            guard let leaf = AmachLeafV2.deserialize(from: bytes) else {
                return XCTFail("\(fx.name): deserialize returned nil")
            }
            XCTAssertEqual(leaf.serialize(), bytes, "\(fx.name): serialize round-trip mismatch")
            XCTAssertNoThrow(try leaf.validate(), "\(fx.name): conformant leaf must validate")
        }
    }

    func testCrossPlatformChunksAreFieldElements() {
        // Chunks must each be < BN128 field size. With 31-byte chunks (< 2^248)
        // this is structurally guaranteed, but we assert it explicitly so
        // any future schema change that promotes a chunk past 31 bytes fails
        // here loudly instead of producing silently invalid hashes.
        let bn128 = BigUInt(
            "21888242871839275222246405745257275088548364400416034343698204186575808495617"
        )!
        for fx in Self.crossPlatformFixtures {
            guard let bytes = Data(hexString: fx.hex),
                  let chunks = AmachLeafV2.chunks(from: bytes) else {
                return XCTFail("\(fx.name): chunk decode failed")
            }
            for (i, chunkData) in [chunks.chunk1, chunks.chunk2, chunks.chunk3, chunks.chunk4].enumerated() {
                XCTAssertEqual(chunkData.count, 31, "\(fx.name) chunk\(i+1) must be 31 bytes")
                let chunkInt = BigUInt(hexString: chunkData.hexString) ?? BigUInt(0)
                XCTAssertTrue(chunkInt < bn128, "\(fx.name) chunk\(i+1) must be < BN128 field size")
            }
        }
    }

    /// The expected-hash decimals are mirrored from JS. We cannot recompute
    /// Poseidon4 in Swift without bundling a Poseidon implementation (the
    /// production pipeline shells out to Node — see LeafHashingService). What
    /// we *can* assert here is that the Swift-serialized bytes are byte-
    /// identical to the JS-serialized bytes for which the JS test pinned
    /// the expected hash. That equality plus the JS hash assertion in
    /// hash_leaf.test.js is the cross-platform consistency proof.
    func testSwiftSerializationMatchesPinnedJSVectorBytes() {
        // Build each fixture from typed inputs (mirroring what the Swift
        // builder would produce in production), then assert the bytes
        // equal the JS-pinned hex. If this passes, the JS Jest assertion
        // that those exact bytes hash to expectedHashDec proves that any
        // Swift caller that hashes via LeafHashingService → hash_leaf.js
        // gets the same hash.
        for (fx, expectedLeaf) in zip(Self.crossPlatformFixtures, makeFixtureLeaves()) {
            let bytes = expectedLeaf.serialize()
            XCTAssertEqual(
                bytes.hexString,
                fx.hex,
                "\(fx.name): Swift serialization differs from pinned JS vector"
            )
        }
    }

    // MARK: - Fixture leaf builders (mirror v2_test_vectors.js)

    private func makeFixtureLeaves() -> [AmachLeafV2] {
        return [
            // zeros_envelope_only
            AmachLeafV2(
                wallet: Data(repeating: 0, count: 32), dayId: 0, timezoneOffset: 0,
                steps: 0, activeEnergy: 0, exerciseMins: 0, hrv: 0, restingHR: 0, sleepMins: 0,
                workoutCount: 0, sourceCount: 0, dataFlags: 0,
                vo2max: 0, weight: 0, bodyFatPct: 0, leanMass: 0,
                deepSleepMins: 0, remSleepMins: 0, lightSleepMins: 0, awakeMins: 0,
                sourceHash: Data(repeating: 0, count: 32)
            ),
            // default_mid_range
            makeDefaultLeaf(),
            // all_max
            AmachLeafV2(
                wallet: Data(repeating: 0xFF, count: 32),
                dayId: UInt32.max, timezoneOffset: Int16.max,
                steps: UInt32.max, activeEnergy: UInt32.max,
                exerciseMins: UInt16.max, hrv: UInt16.max, restingHR: UInt16.max, sleepMins: UInt16.max,
                workoutCount: UInt8.max, sourceCount: UInt8.max, dataFlags: UInt32.max,
                vo2max: UInt16.max, weight: UInt16.max, bodyFatPct: UInt16.max, leanMass: UInt16.max,
                deepSleepMins: UInt16.max, remSleepMins: UInt16.max,
                lightSleepMins: UInt16.max, awakeMins: UInt16.max,
                sourceHash: Data(repeating: 0xFF, count: 32)
            ),
            // elite_athlete
            AmachLeafV2(
                wallet: Data(hexString: "1111111111111111111111111111111111111111111111111111111111111111")!,
                dayId: 365 + 90, timezoneOffset: -480,
                steps: 14237, activeEnergy: 92500,
                exerciseMins: 95, hrv: 854, restingHR: 420, sleepMins: 480,
                workoutCount: 2, sourceCount: 2, dataFlags: 0x000F_03FF,
                vo2max: 612, weight: 7350, bodyFatPct: 1180, leanMass: 6480,
                deepSleepMins: 110, remSleepMins: 105, lightSleepMins: 245, awakeMins: 20,
                sourceHash: Data(hexString: "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899")!
            ),
            // sedentary_minimal
            AmachLeafV2(
                wallet: Data(hexString: "00000000000000000000000000000000000000000000000000000000000000ab")!,
                dayId: 100, timezoneOffset: 0,
                steps: 1200, activeEnergy: 4500,
                exerciseMins: 0, hrv: 0, restingHR: 720, sleepMins: 360,
                workoutCount: 0, sourceCount: 1, dataFlags: 0x0000_0021,
                vo2max: 0, weight: 8200, bodyFatPct: 0, leanMass: 0,
                deepSleepMins: 30, remSleepMins: 50, lightSleepMins: 260, awakeMins: 20,
                sourceHash: Data(repeating: 0x11, count: 32)
            )
        ]
    }

    // MARK: - Helpers

    private func makeDefaultLeaf() -> AmachLeafV2 {
        // Mirrors buildTestLeafV2() defaults in zk/scripts/hash_leaf.js.
        AmachLeafV2(
            wallet: Data(repeating: 0xAB, count: 32),
            dayId: 42,
            timezoneOffset: -300,
            steps: 8500,
            activeEnergy: 35000,
            exerciseMins: 60,
            hrv: 412,
            restingHR: 560,
            sleepMins: 450,
            workoutCount: 2,
            sourceCount: 3,
            dataFlags: 0x000F_03FF,
            vo2max: 425,
            weight: 7800,
            bodyFatPct: 1850,
            leanMass: 6300,
            deepSleepMins: 75,
            remSleepMins: 95,
            lightSleepMins: 240,
            awakeMins: 20,
            sourceHash: Data(repeating: 0xCC, count: 32)
        )
    }
}

// MARK: - Test-only mutators that bypass the convenience init's envelope defaults

private extension AmachLeafV2 {
    func withRawEnvelope(
        version: UInt8? = nil,
        leafType: UInt8? = nil,
        schemaVersion: UInt8? = nil,
        reservedEnvelope: UInt8? = nil
    ) -> AmachLeafV2 {
        AmachLeafV2(
            version: version ?? self.version,
            leafType: leafType ?? self.leafType,
            schemaVersion: schemaVersion ?? self.schemaVersion,
            reservedEnvelope: reservedEnvelope ?? self.reservedEnvelope,
            wallet: wallet, dayId: dayId, timezoneOffset: timezoneOffset,
            steps: steps, activeEnergy: activeEnergy, exerciseMins: exerciseMins,
            hrv: hrv, restingHR: restingHR, sleepMins: sleepMins,
            workoutCount: workoutCount, sourceCount: sourceCount, dataFlags: dataFlags,
            vo2max: vo2max, weight: weight, bodyFatPct: bodyFatPct, leanMass: leanMass,
            deepSleepMins: deepSleepMins, remSleepMins: remSleepMins,
            lightSleepMins: lightSleepMins, awakeMins: awakeMins,
            reservedPayload: reservedPayload, sourceHash: sourceHash
        )
    }

    func withReservedPayload(_ payload: Data) -> AmachLeafV2 {
        AmachLeafV2(
            version: version, leafType: leafType, schemaVersion: schemaVersion,
            reservedEnvelope: reservedEnvelope,
            wallet: wallet, dayId: dayId, timezoneOffset: timezoneOffset,
            steps: steps, activeEnergy: activeEnergy, exerciseMins: exerciseMins,
            hrv: hrv, restingHR: restingHR, sleepMins: sleepMins,
            workoutCount: workoutCount, sourceCount: sourceCount, dataFlags: dataFlags,
            vo2max: vo2max, weight: weight, bodyFatPct: bodyFatPct, leanMass: leanMass,
            deepSleepMins: deepSleepMins, remSleepMins: remSleepMins,
            lightSleepMins: lightSleepMins, awakeMins: awakeMins,
            reservedPayload: payload, sourceHash: sourceHash
        )
    }

    func withWallet(_ w: Data) -> AmachLeafV2 {
        AmachLeafV2(
            version: version, leafType: leafType, schemaVersion: schemaVersion,
            reservedEnvelope: reservedEnvelope,
            wallet: w, dayId: dayId, timezoneOffset: timezoneOffset,
            steps: steps, activeEnergy: activeEnergy, exerciseMins: exerciseMins,
            hrv: hrv, restingHR: restingHR, sleepMins: sleepMins,
            workoutCount: workoutCount, sourceCount: sourceCount, dataFlags: dataFlags,
            vo2max: vo2max, weight: weight, bodyFatPct: bodyFatPct, leanMass: leanMass,
            deepSleepMins: deepSleepMins, remSleepMins: remSleepMins,
            lightSleepMins: lightSleepMins, awakeMins: awakeMins,
            reservedPayload: reservedPayload, sourceHash: sourceHash
        )
    }

    func withSourceHash(_ s: Data) -> AmachLeafV2 {
        AmachLeafV2(
            version: version, leafType: leafType, schemaVersion: schemaVersion,
            reservedEnvelope: reservedEnvelope,
            wallet: wallet, dayId: dayId, timezoneOffset: timezoneOffset,
            steps: steps, activeEnergy: activeEnergy, exerciseMins: exerciseMins,
            hrv: hrv, restingHR: restingHR, sleepMins: sleepMins,
            workoutCount: workoutCount, sourceCount: sourceCount, dataFlags: dataFlags,
            vo2max: vo2max, weight: weight, bodyFatPct: bodyFatPct, leanMass: leanMass,
            deepSleepMins: deepSleepMins, remSleepMins: remSleepMins,
            lightSleepMins: lightSleepMins, awakeMins: awakeMins,
            reservedPayload: reservedPayload, sourceHash: s
        )
    }
}

// MARK: - Hex helpers and a tiny BigUInt for the BN128 bound check

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        let s = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard s.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(s[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self.init(bytes)
    }
}

/// Minimal big-unsigned integer for the BN128 bound assertion. Avoids pulling
/// in a full bignum library just for one comparison in tests.
private struct BigUInt: Comparable {
    let words: [UInt32] // big-endian

    init?(_ decimal: String) {
        var current = BigUInt(words: [0])
        for ch in decimal {
            guard let d = ch.hexDigitValue, d < 10 else { return nil }
            current = current.multiplied(by: 10).adding(UInt32(d))
        }
        self = current
    }

    init?(hexString: String) {
        let s = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        var current = BigUInt(words: [0])
        for ch in s {
            guard let d = ch.hexDigitValue else { return nil }
            current = current.multiplied(by: 16).adding(UInt32(d))
        }
        self = current
    }

    init(_ value: UInt32) { self.words = [value] }
    private init(words: [UInt32]) { self.words = words.isEmpty ? [0] : words }

    func multiplied(by scalar: UInt32) -> BigUInt {
        var result: [UInt64] = Array(repeating: 0, count: words.count + 1)
        for i in 0..<words.count {
            let idx = words.count - 1 - i
            let prod = UInt64(words[idx]) * UInt64(scalar)
            let carryIdx = result.count - 1 - i
            let sum = result[carryIdx] + prod
            result[carryIdx] = sum & 0xFFFF_FFFF
            result[carryIdx - 1] += sum >> 32
        }
        // Compact carry chain
        var compacted = result
        for i in stride(from: compacted.count - 1, to: 0, by: -1) {
            if compacted[i] >> 32 != 0 {
                compacted[i - 1] += compacted[i] >> 32
                compacted[i] &= 0xFFFF_FFFF
            }
        }
        var trimmed = compacted.map { UInt32($0 & 0xFFFF_FFFF) }
        while trimmed.count > 1 && trimmed[0] == 0 { trimmed.removeFirst() }
        return BigUInt(words: trimmed)
    }

    func adding(_ scalar: UInt32) -> BigUInt {
        var w = words
        var carry = UInt64(scalar)
        var i = w.count - 1
        while carry > 0 && i >= 0 {
            let sum = UInt64(w[i]) + carry
            w[i] = UInt32(sum & 0xFFFF_FFFF)
            carry = sum >> 32
            i -= 1
        }
        if carry > 0 { w.insert(UInt32(carry), at: 0) }
        return BigUInt(words: w)
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        // Trim leading zeros for fair comparison
        let l = trim(lhs.words), r = trim(rhs.words)
        if l.count != r.count { return l.count < r.count }
        for (a, b) in zip(l, r) where a != b { return a < b }
        return false
    }

    static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        trim(lhs.words) == trim(rhs.words)
    }

    private static func trim(_ w: [UInt32]) -> [UInt32] {
        var out = w
        while out.count > 1 && out[0] == 0 { out.removeFirst() }
        return out
    }
}
