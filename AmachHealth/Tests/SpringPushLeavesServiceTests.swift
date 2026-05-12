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
            bloodOxygenPresent: false,
            vo2max: 0,
            weight: 0,
            bodyFatPct: 0,
            leanMass: 0,
            deepSleepMins: 0,
            remSleepMins: 0,
            lightSleepMins: 0,
            awakeMins: 0,
            vo2maxPresent: false,
            weightPresent: false,
            bodyFatPctPresent: false,
            leanMassPresent: false,
            sleepStagesPresent: false
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

    func test_init_passes_through_zero_v2_metrics_when_absent() {
        // Days with no v2 samples at all → all v2 fields are zero. The
        // *Present flags on NormalizedDailyLeaf are what differentiate
        // "metric not recorded today" from "recorded as zero" upstream.
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

    func test_init_passes_through_v2_metrics_when_present() {
        // Matches the encoded values from hash_leaf.js buildTestLeafV2:
        // 42.5 ml/(kg·min) → 425; 78.00 kg → 7800; 18.50% → 1850;
        // 63.00 kg lean → 6300.
        let leaf = makeNormalizedLeaf(
            vo2max: 425,
            weight: 7800,
            bodyFatPct: 1850,
            leanMass: 6300,
            deep: 75,
            rem: 95,
            light: 240,
            awake: 20
        )
        let v2 = MerkleLeafV2Fields(from: leaf, walletAddress: "0xabc")
        XCTAssertEqual(v2.vo2max, 425)
        XCTAssertEqual(v2.weight, 7800)
        XCTAssertEqual(v2.bodyFatPct, 1850)
        XCTAssertEqual(v2.leanMass, 6300)
        XCTAssertEqual(v2.deepSleepMins, 75)
        XCTAssertEqual(v2.remSleepMins, 95)
        XCTAssertEqual(v2.lightSleepMins, 240)
        XCTAssertEqual(v2.awakeMins, 20)
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
        sourceHashBytes: Data = Data(repeating: 0, count: 32),
        vo2max: UInt16 = 0,
        weight: UInt16 = 0,
        bodyFatPct: UInt16 = 0,
        leanMass: UInt16 = 0,
        deep: UInt16 = 0,
        rem: UInt16 = 0,
        light: UInt16 = 0,
        awake: UInt16 = 0
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
            bloodOxygenPresent: false,
            vo2max: vo2max,
            weight: weight,
            bodyFatPct: bodyFatPct,
            leanMass: leanMass,
            deepSleepMins: deep,
            remSleepMins: rem,
            lightSleepMins: light,
            awakeMins: awake,
            vo2maxPresent: vo2max > 0,
            weightPresent: weight > 0,
            bodyFatPctPresent: bodyFatPct > 0,
            leanMassPresent: leanMass > 0,
            sleepStagesPresent: deep + rem + light + awake > 0
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

// MARK: - SpringPushLeavesService.parseSampleValue (sleep-stage data path)

final class SpringPushParseSampleValueTests: XCTestCase {

    func test_parses_sleep_stage_names_to_HKCategoryValueSleepAnalysis() {
        // HealthKitService stringifies sleep samples to readable stage
        // names before storing them in HealthDataPoint.value. The v2
        // normalizer expects integer category values to bucket by stage,
        // so SpringPushLeavesService.parseSampleValue must reverse that.
        let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
        XCTAssertEqual(SpringPushLeavesService.parseSampleValue("inBed", metricType: sleep), 0)
        XCTAssertEqual(SpringPushLeavesService.parseSampleValue("asleep", metricType: sleep), 1)
        XCTAssertEqual(SpringPushLeavesService.parseSampleValue("awake", metricType: sleep), 2)
        XCTAssertEqual(SpringPushLeavesService.parseSampleValue("core", metricType: sleep), 3)
        XCTAssertEqual(SpringPushLeavesService.parseSampleValue("deep", metricType: sleep), 4)
        XCTAssertEqual(SpringPushLeavesService.parseSampleValue("rem", metricType: sleep), 5)
    }

    func test_unknown_sleep_stage_falls_back_to_numeric_parse() {
        let sleep = "HKCategoryTypeIdentifierSleepAnalysis"
        // Source that wrote the raw enum integer (rare, but supported).
        XCTAssertEqual(SpringPushLeavesService.parseSampleValue("4", metricType: sleep), 4)
        // Garbage → 0, same fallback as the rest of the pipeline.
        XCTAssertEqual(SpringPushLeavesService.parseSampleValue("garbage", metricType: sleep), 0)
    }

    func test_non_sleep_samples_parsed_as_doubles() {
        XCTAssertEqual(
            SpringPushLeavesService.parseSampleValue("42.5", metricType: "HKQuantityTypeIdentifierVO2Max"),
            42.5
        )
        XCTAssertEqual(
            SpringPushLeavesService.parseSampleValue("notanumber", metricType: "HKQuantityTypeIdentifierStepCount"),
            0
        )
    }
}

// MARK: - MerkleNormalizationService v2 metric tests

final class MerkleNormalizationV2Tests: XCTestCase {

    private let wallet = Data(repeating: 0xAB, count: 32)
    private let timezone = TimeZone(identifier: "UTC")!
    private lazy var dayStart: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timezone
        return cal.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    }()
    private lazy var dayEnd: Date = dayStart.addingTimeInterval(86_400)

    private func service() -> MerkleNormalizationService {
        MerkleNormalizationService(walletAddress: wallet)
    }

    // MARK: VO₂ max

    func test_vo2max_averages_daily_samples_and_encodes_x10_round_half_up() {
        // 42.5 and 43.5 → mean 43.0 → 430 (encoded as ml/(kg·min) × 10).
        let samples = [
            sample(metric: "HKQuantityTypeIdentifierVO2Max", value: 42.5, at: 100),
            sample(metric: "HKQuantityTypeIdentifierVO2Max", value: 43.5, at: 200),
        ]
        let leaf = service().normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: dayStart, end: dayEnd, timezone: timezone
        ).first!
        XCTAssertTrue(leaf.vo2maxPresent)
        XCTAssertEqual(leaf.vo2max, 430)
    }

    func test_vo2max_rounds_half_up_at_the_tenths_boundary() {
        // 42.55 → 425.5 → round half-up to 426.
        let samples = [
            sample(metric: "HKQuantityTypeIdentifierVO2Max", value: 42.55, at: 0)
        ]
        let leaf = service().normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: dayStart, end: dayEnd, timezone: timezone
        ).first!
        XCTAssertEqual(leaf.vo2max, 426)
    }

    func test_vo2max_absent_when_no_samples_for_the_day() {
        let leaf = service().normalize(
            samples: [sample(metric: "HKQuantityTypeIdentifierStepCount", value: 5000, at: 0)],
            workouts: [], restingHRSamples: [],
            start: dayStart, end: dayEnd, timezone: timezone
        ).first!
        XCTAssertFalse(leaf.vo2maxPresent)
        XCTAssertEqual(leaf.vo2max, 0)
    }

    // MARK: Body composition

    func test_weight_uses_most_recent_sample_and_encodes_kg_x100() {
        // Three readings the same day; the latest one (78.00 kg) wins.
        let samples = [
            sample(metric: "HKQuantityTypeIdentifierBodyMass", value: 80.00, at: 100),
            sample(metric: "HKQuantityTypeIdentifierBodyMass", value: 79.50, at: 200),
            sample(metric: "HKQuantityTypeIdentifierBodyMass", value: 78.00, at: 300),
        ]
        let leaf = service().normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: dayStart, end: dayEnd, timezone: timezone
        ).first!
        XCTAssertTrue(leaf.weightPresent)
        XCTAssertEqual(leaf.weight, 7800)
    }

    func test_bodyFatPct_converts_fraction_to_basis_points_round_half_up() {
        // HealthKit body fat is a fraction (0.185 = 18.5%). Encoded as
        // fraction × 10000 → 1850 basis points.
        let samples = [
            sample(metric: "HKQuantityTypeIdentifierBodyFatPercentage", value: 0.185, at: 0)
        ]
        let leaf = service().normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: dayStart, end: dayEnd, timezone: timezone
        ).first!
        XCTAssertTrue(leaf.bodyFatPctPresent)
        XCTAssertEqual(leaf.bodyFatPct, 1850)
    }

    func test_leanMass_uses_most_recent_sample_and_encodes_kg_x100() {
        let samples = [
            sample(metric: "HKQuantityTypeIdentifierLeanBodyMass", value: 62.00, at: 100),
            sample(metric: "HKQuantityTypeIdentifierLeanBodyMass", value: 63.00, at: 200),
        ]
        let leaf = service().normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: dayStart, end: dayEnd, timezone: timezone
        ).first!
        XCTAssertEqual(leaf.leanMass, 6300)
        XCTAssertTrue(leaf.leanMassPresent)
    }

    // MARK: Sleep stages

    func test_sleep_stages_bucket_by_HKCategoryValue_and_sum_minutes() {
        // 75 min deep (value=4), 95 min REM (5), 240 min light/core (3),
        // 20 min awake (2). Matches the encoded values in
        // hash_leaf.js buildTestLeafV2.
        let samples = [
            sleepSample(stage: 4, minutes: 75, at: 100),
            sleepSample(stage: 5, minutes: 95, at: 200),
            sleepSample(stage: 3, minutes: 240, at: 300),
            sleepSample(stage: 2, minutes: 20, at: 400),
        ]
        let leaf = service().normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: dayStart, end: dayEnd, timezone: timezone
        ).first!
        XCTAssertEqual(leaf.deepSleepMins, 75)
        XCTAssertEqual(leaf.remSleepMins, 95)
        XCTAssertEqual(leaf.lightSleepMins, 240)
        XCTAssertEqual(leaf.awakeMins, 20)
        XCTAssertTrue(leaf.sleepStagesPresent)
    }

    func test_sleep_inBed_and_unspecified_are_skipped() {
        // `inBed` (0) overlaps with per-stage samples and would
        // double-count. `asleepUnspecified` (1) can't be attributed to
        // any stage bucket. Both must be ignored.
        let samples = [
            sleepSample(stage: 0, minutes: 480, at: 100),   // inBed — skip
            sleepSample(stage: 1, minutes: 60, at: 200),    // unspecified — skip
            sleepSample(stage: 4, minutes: 75, at: 300),    // deep
        ]
        let leaf = service().normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: dayStart, end: dayEnd, timezone: timezone
        ).first!
        XCTAssertEqual(leaf.deepSleepMins, 75)
        XCTAssertEqual(leaf.remSleepMins, 0)
        XCTAssertEqual(leaf.lightSleepMins, 0)
        XCTAssertEqual(leaf.awakeMins, 0)
        XCTAssertTrue(leaf.sleepStagesPresent)
    }

    func test_sleep_stages_absent_when_only_unspecified_samples_present() {
        let samples = [
            sleepSample(stage: 0, minutes: 480, at: 100),   // inBed — skip
            sleepSample(stage: 1, minutes: 420, at: 200),   // unspecified — skip
        ]
        let leaf = service().normalize(
            samples: samples, workouts: [], restingHRSamples: [],
            start: dayStart, end: dayEnd, timezone: timezone
        ).first!
        XCTAssertFalse(leaf.sleepStagesPresent)
        XCTAssertEqual(leaf.deepSleepMins + leaf.remSleepMins + leaf.lightSleepMins + leaf.awakeMins, 0)
    }

    // MARK: Helpers

    private func sample(metric: String, value: Double, at offsetSeconds: TimeInterval) -> HealthSample {
        let date = dayStart.addingTimeInterval(offsetSeconds)
        return HealthSample(
            metricType: metric,
            value: value,
            unit: "",
            startDate: date,
            endDate: date,
            sourceBundleID: "com.apple.health",
            device: nil
        )
    }

    private func sleepSample(stage: Int, minutes: Int, at offsetSeconds: TimeInterval) -> HealthSample {
        let start = dayStart.addingTimeInterval(offsetSeconds)
        let end = start.addingTimeInterval(Double(minutes) * 60)
        return HealthSample(
            metricType: "HKCategoryTypeIdentifierSleepAnalysis",
            value: Double(stage),
            unit: "",
            startDate: start,
            endDate: end,
            sourceBundleID: "com.apple.health.sleep",
            device: nil
        )
    }
}
