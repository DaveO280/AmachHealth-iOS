// SpringPushLeavesServiceTests.swift
// AmachHealthTests
//
// Pure JSON / value-mapping tests for the Spring Push leaves uploader.
// HealthKit and live API calls are out of scope — those paths are exercised
// in MerkleNormalizationTests and the website-side helpers.test.ts.

import XCTest
@testable import AmachHealth

final class MerkleLeafV2FieldsTests: XCTestCase {

    // MARK: - init(from: NormalizedDailyLeaf, walletAddress:)

    func test_init_maps_all_v1_fields_directly() {
        let walletData = Data(repeating: 0xAB, count: 32)
        let leaf = NormalizedDailyLeaf(
            dayId: 1234,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            timezone: TimeZone(identifier: "America/New_York")!,
            walletAddress: walletData,
            steps: 9_876,
            activeEnergy: 35_050,
            exerciseMins: 47,
            hrv: 412,
            restingHR: 580,
            sleepMins: 451,
            workoutCount: 2,
            sourceCount: 3,
            dataFlags: 0b0000_0001_0111_1111,
            sourceHash: Data(repeating: 0xCC, count: 32),
            hrvPresent: true,
            restingHRPresent: true,
            bloodOxygenPresent: false
        )

        let v2 = MerkleLeafV2Fields(from: leaf, walletAddress: "0xdead")

        XCTAssertEqual(v2.wallet, "0xdead")
        XCTAssertEqual(v2.dayId, 1234)
        XCTAssertEqual(v2.steps, 9_876)
        XCTAssertEqual(v2.activeEnergy, 35_050)
        XCTAssertEqual(v2.exerciseMins, 47)
        XCTAssertEqual(v2.hrv, 412)
        XCTAssertEqual(v2.restingHR, 580)
        XCTAssertEqual(v2.sleepMins, 451)
        XCTAssertEqual(v2.workoutCount, 2)
        XCTAssertEqual(v2.sourceCount, 3)
        XCTAssertEqual(v2.dataFlags, UInt32(0b0000_0001_0111_1111))
        XCTAssertEqual(v2.sourceHash, String(repeating: "cc", count: 32))
    }

    func test_init_widens_dataFlags_into_u32_clearing_upper_bits() {
        let leaf = makeNormalizedLeaf(dataFlags: UInt16.max)
        let v2 = MerkleLeafV2Fields(from: leaf, walletAddress: "0xabc")
        XCTAssertEqual(v2.dataFlags, UInt32(UInt16.max))
        // Upper half must be zero — reserved for future v2 flag bits.
        XCTAssertEqual(v2.dataFlags & 0xFFFF_0000, 0)
    }

    func test_init_zeroes_v2_only_metrics_pending_normalizer_support() {
        // Until MerkleNormalizationService grows v2 outputs, every v2-only
        // metric must be 0. The Spring Push improvement circuit's vo2max
        // pointer reading 0 is acceptable for plumbing, but is the gate
        // for "ready for proof generation" that the future UI checks.
        let v2 = MerkleLeafV2Fields(from: makeNormalizedLeaf(), walletAddress: "0xabc")
        XCTAssertEqual(v2.vo2max, 0)
        XCTAssertEqual(v2.weight, 0)
        XCTAssertEqual(v2.bodyFatPct, 0)
        XCTAssertEqual(v2.leanMass, 0)
        XCTAssertEqual(v2.deepSleepMins, 0)
        XCTAssertEqual(v2.remSleepMins, 0)
        XCTAssertEqual(v2.lightSleepMins, 0)
        XCTAssertEqual(v2.awakeMins, 0)
    }

    func test_init_encodes_timezone_offset_in_minutes() {
        let est = makeNormalizedLeaf(timezone: TimeZone(identifier: "America/New_York")!)
        let estLeaf = MerkleLeafV2Fields(from: est, walletAddress: "0xabc")
        // NY is UTC-5 (or -4 in DST) — both encode as a negative multiple
        // of 60. Just assert it's negative and a multiple of 60.
        XCTAssertLessThan(estLeaf.timezoneOffset, 0)
        XCTAssertEqual(estLeaf.timezoneOffset % 60, 0)

        let utc = makeNormalizedLeaf(timezone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(MerkleLeafV2Fields(from: utc, walletAddress: "0xabc").timezoneOffset, 0)
    }

    func test_init_leaves_envelope_overrides_nil() {
        let v2 = MerkleLeafV2Fields(from: makeNormalizedLeaf(), walletAddress: "0xabc")
        XCTAssertNil(v2.version)
        XCTAssertNil(v2.leafType)
        XCTAssertNil(v2.schemaVersion)
        XCTAssertNil(v2.reservedEnvelope)
        // reservedPayload defaults to nil → server fills 12 zero bytes.
        XCTAssertNil(v2.reservedPayload)
    }

    // MARK: - JSON encoding shape

    func test_json_encoding_matches_TS_AmachLeafV2Fields_wire_shape() throws {
        let v2 = MerkleLeafV2Fields(
            from: makeNormalizedLeaf(),
            walletAddress: "0xabababababababababababababababababababab"
        )
        let data = try JSONEncoder().encode(v2)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // Required fields — every v2 leaf must always carry these.
        let requiredKeys: Set<String> = [
            "wallet", "dayId", "timezoneOffset",
            "steps", "activeEnergy", "exerciseMins", "hrv", "restingHR",
            "sleepMins", "workoutCount", "sourceCount", "dataFlags",
            "vo2max", "weight", "bodyFatPct", "leanMass",
            "deepSleepMins", "remSleepMins", "lightSleepMins", "awakeMins",
        ]
        for key in requiredKeys {
            XCTAssertNotNil(json[key], "missing required wire key: \(key)")
        }

        // Optional envelope overrides — must be absent when nil so the
        // server picks the v2 daily_summary defaults.
        for absentKey in ["version", "leafType", "schemaVersion", "reservedEnvelope", "reservedPayload"] {
            XCTAssertNil(json[absentKey], "envelope override should be absent: \(absentKey)")
        }

        XCTAssertEqual(json["wallet"] as? String, "0xabababababababababababababababababababab")
    }

    func test_json_encoding_includes_sourceHash_as_hex_string() throws {
        let leaf = makeNormalizedLeaf(sourceHashBytes: Data([0x01, 0x02, 0x03]))
        let v2 = MerkleLeafV2Fields(from: leaf, walletAddress: "0xabc")
        let data = try JSONEncoder().encode(v2)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["sourceHash"] as? String, "010203")
    }

    // MARK: - Helpers

    private func makeNormalizedLeaf(
        dayId: UInt32 = 100,
        timezone: TimeZone = TimeZone(identifier: "UTC")!,
        dataFlags: UInt16 = 0,
        sourceHashBytes: Data = Data(repeating: 0, count: 32)
    ) -> NormalizedDailyLeaf {
        NormalizedDailyLeaf(
            dayId: dayId,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            timezone: timezone,
            walletAddress: Data(repeating: 0xAB, count: 32),
            steps: 1000,
            activeEnergy: 0,
            exerciseMins: 0,
            hrv: 0,
            restingHR: 0,
            sleepMins: 0,
            workoutCount: 0,
            sourceCount: 1,
            dataFlags: dataFlags,
            sourceHash: sourceHashBytes,
            hrvPresent: false,
            restingHRPresent: false,
            bloodOxygenPresent: false
        )
    }
}

// MARK: - SpringPushLeavesService.parseWalletAddress

final class SpringPushWalletParsingTests: XCTestCase {

    func test_parses_20_byte_evm_address_right_aligned_into_32_bytes() {
        let addr = "0x" + String(repeating: "ab", count: 20)
        let parsed = SpringPushLeavesService.parseWalletAddress(addr)
        XCTAssertEqual(parsed.count, 32)
        // Leading 12 bytes must be zero (left-padding for EVM addresses).
        for i in 0..<12 {
            XCTAssertEqual(parsed[i], 0, "byte \(i) must be zero (left-pad)")
        }
        // Trailing 20 bytes must be the wallet bytes.
        for i in 12..<32 {
            XCTAssertEqual(parsed[i], 0xAB, "byte \(i) must be 0xAB")
        }
    }

    func test_accepts_address_without_0x_prefix() {
        let withPrefix = SpringPushLeavesService.parseWalletAddress(
            "0x" + String(repeating: "ab", count: 20)
        )
        let without = SpringPushLeavesService.parseWalletAddress(
            String(repeating: "ab", count: 20)
        )
        XCTAssertEqual(withPrefix, without)
    }

    func test_preserves_full_32_byte_synthetic_wallet() {
        // The hash_leaf.js v2 test fixture uses a 32-byte wallet (all
        // 0xAB) — make sure we preserve all 32 bytes, not truncate to 20.
        // Drift here would silently break Swift/JS hash parity for any
        // future tests that use 32-byte test wallets.
        let parsed = SpringPushLeavesService.parseWalletAddress(
            "0x" + String(repeating: "ab", count: 32)
        )
        XCTAssertEqual(parsed.count, 32)
        XCTAssertEqual(parsed, Data(repeating: 0xAB, count: 32))
    }

    func test_handles_uppercase_0X_prefix() {
        let lower = SpringPushLeavesService.parseWalletAddress("0xabcdef")
        let upper = SpringPushLeavesService.parseWalletAddress("0XABCDEF")
        XCTAssertEqual(lower, upper)
    }
}

// MARK: - MerkleV2 upload request body shape

final class MerkleV2UploadRequestShapeTests: XCTestCase {

    /// Mirror of the inline `UploadRequest` struct in
    /// `AmachAPIClient.uploadMerkleV2Leaves`. The route on the website
    /// reads these exact field names — see the wire contract docstring
    /// in `Amach-Website/src/app/api/merkle/v2/upload/helpers.ts`.
    struct UploadRequestWire: Encodable {
        let walletAddress: String
        let encryptionKey: WalletEncryptionKey
        let window: String
        let leaves: [MerkleLeafV2Fields]
    }

    func test_request_body_keys_match_server_route_contract() throws {
        let key = WalletEncryptionKey(
            walletAddress: "0xabc",
            encryptionKey: "deadbeef",
            signature: "0xsig",
            timestamp: 1_700_000_000
        )
        let body = UploadRequestWire(
            walletAddress: "0xabc",
            encryptionKey: key,
            window: MerkleV2UploadWindow.baseline.rawValue,
            leaves: []
        )
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(json.keys), Set(["walletAddress", "encryptionKey", "window", "leaves"]))
        XCTAssertEqual(json["window"] as? String, "baseline")

        // The web's WalletEncryptionKey expects { walletAddress, key,
        // signature, derivedAt } — that's the Swift Codable rename in
        // AmachAPIClient.swift. Spot-check it survived encoding.
        let encKey = try XCTUnwrap(json["encryptionKey"] as? [String: Any])
        XCTAssertEqual(Set(encKey.keys), Set(["walletAddress", "key", "signature", "derivedAt"]))
    }

    func test_window_enum_rawValues_match_dataType_suffixes() {
        // The server maps window → dataType. Asserting the raw values
        // here prevents an accidental rename from breaking the wire
        // contract silently.
        XCTAssertEqual(MerkleV2UploadWindow.baseline.rawValue, "baseline")
        XCTAssertEqual(MerkleV2UploadWindow.finish.rawValue, "finish")
    }
}
