// StorjImportTests.swift
// AmachHealthTests
//
// StorjObjectImporter against objects encrypted by the website's code
// (WalletDecryptorFixtures.importCases): every dataType lands in the right
// table, units are normalized, duplicates and failures are recorded.

import XCTest
@testable import AmachHealth

final class StorjImportTests: XCTestCase {

    private var vault: VaultDatabase!
    private var importer: StorjObjectImporter!
    private let passphrase = WalletDecryptorFixtures.encryptionKey

    override func setUpWithError() throws {
        vault = try VaultDatabase.inMemory()
        importer = StorjObjectImporter(vault: vault)
    }

    private func fixture(_ name: String) throws -> WalletDecryptorFixtures.ImportCase {
        try XCTUnwrap(WalletDecryptorFixtures.importCases.first { $0.name == name }, name)
    }

    private func object(_ c: WalletDecryptorFixtures.ImportCase) -> AmachAPIClient.RawStorjObject {
        AmachAPIClient.RawStorjObject(key: c.key, size: c.objectText.utf8.count, dataType: c.dataType, uploadedAt: c.uploadedAt)
    }

    @discardableResult
    private func run(_ name: String) throws -> StorjObjectImporter.Outcome {
        let c = try fixture(name)
        let outcome = importer.importObject(object(c), bytes: Data(c.objectText.utf8), passphrase: passphrase)
        importer.recordStatus(outcome, object: object(c))
        return outcome
    }

    private func status(_ name: String) throws -> StorjImportRow? {
        let key = try fixture(name).key
        return try vault.dbQueue.read { db in try StorjImportRow.fetchOne(db, key: key) }
    }

    // MARK: - Full run

    func test_importing_every_fixture_records_each_object_and_nothing_fails() throws {
        var report = ImportReport(objectsListed: WalletDecryptorFixtures.importCases.count, previouslyImported: 0)
        for c in WalletDecryptorFixtures.importCases {
            let outcome = importer.importObject(object(c), bytes: Data(c.objectText.utf8), passphrase: passphrase)
            importer.recordStatus(outcome, object: object(c))
            report.record(outcome, object: object(c))
        }
        XCTAssertEqual(report.failures, [], "\(report.failures)")
        let rows = try vault.dbQueue.read { db in try StorjImportRow.fetchCount(db) }
        XCTAssertEqual(rows, WalletDecryptorFixtures.importCases.count, "every object gets a storj_imports row")
        XCTAssertEqual(report.archived, 1, "health-scores has no table yet and is kept as JSON")
    }

    // MARK: - Apple Health

    func test_ios_apple_health_payload_maps_to_amach_metrics_and_units() throws {
        try run("appleHealthIOS")
        XCTAssertEqual(try vault.dailyMetric(metric: "steps", day: "2025-10-01")?.total, 9000)
        let hr = try XCTUnwrap(try vault.dailyMetric(metric: "heart_rate", day: "2025-10-01"))
        XCTAssertEqual(hr.avg, 62.5)
        XCTAssertEqual(hr.min, 48)
        XCTAssertEqual(hr.count, 300)
        XCTAssertEqual(hr.source, "import:ios")
        XCTAssertEqual(try vault.dailyMetric(metric: "blood_oxygen", day: "2025-10-01")?.avg ?? 0, 97, accuracy: 0.001, "fraction → %")
        XCTAssertEqual(try vault.dailyMetric(metric: "dietary_water", day: "2025-10-01")?.total, 2500, "L → mL")
        let sleep = try XCTUnwrap(try vault.dailyMetric(metric: "sleep", day: "2025-10-01"))
        XCTAssertEqual(sleep.total, 420)
        XCTAssertEqual(sleep.sleepDeepMin, 80)
        XCTAssertEqual(sleep.sleepEfficiency, 0.89)

        // The unknown metric isn't dropped: the payload is kept with a note.
        let row = try XCTUnwrap(try status("appleHealthIOS"))
        XCTAssertEqual(row.status, "imported")
        XCTAssertTrue(row.detail?.contains("MadeUpMetric") ?? false)
        XCTAssertNotNil(row.payloadJson)
    }

    func test_web_apple_health_payload_and_km_distance() throws {
        try run("appleHealthWeb")
        XCTAssertEqual(try vault.dailyMetric(metric: "steps", day: "2025-09-30")?.total, 7000)
        XCTAssertEqual(try vault.dailyMetric(metric: "steps", day: "2025-09-30")?.source, "import:web")
        XCTAssertEqual(try vault.dailyMetric(metric: "distance_walking_running", day: "2025-09-30")?.total ?? 0, 5200, accuracy: 0.001)
        XCTAssertEqual(try vault.dailyMetric(metric: "resting_heart_rate", day: "2025-09-30")?.avg, 55)
        XCTAssertEqual(try vault.dailyMetric(metric: "sleep", day: "2025-09-30")?.sleepRemMin, 100)
    }

    func test_later_import_overwrites_earlier_import_for_the_same_day() throws {
        try run("appleHealthIOS")   // 2025-10-01 steps 9000
        try run("appleHealthWeb")   // 2025-10-01 steps 1 (uploaded later)
        XCTAssertEqual(try vault.dailyMetric(metric: "steps", day: "2025-10-01")?.total, 1)
    }

    // MARK: - Labs

    func test_website_bloodwork_fhir_is_normalized_with_FhirConverter() throws {
        let outcome = try run("bloodworkFhir")
        guard case .imported(_, let id?, _, _, _) = outcome else { return XCTFail("\(outcome)") }
        let report = try XCTUnwrap(try vault.labReport(id: id))
        XCTAssertEqual(report.report.kind, "bloodwork")
        XCTAssertEqual(report.report.reportDate, "2025-09-15")
        XCTAssertEqual(report.report.laboratory, "Quest Diagnostics")
        XCTAssertEqual(report.markers.map(\.name), ["LDL Cholesterol", "HbA1c", "Hepatitis B Surface Ag"])
        XCTAssertEqual(report.markers[0].value, 128)
        XCTAssertEqual(report.markers[0].flag, "high")
        XCTAssertEqual(report.markers[0].canonicalName, "ldl_cholesterol")
        XCTAssertEqual(report.markers[2].valueText, "Non-reactive")
    }

    func test_narrative_attaches_to_the_report_uploaded_just_before() throws {
        let outcome = try run("bloodworkFhir")
        guard case .imported(_, let id?, _, _, _) = outcome else { return XCTFail("\(outcome)") }
        try run("bloodworkNarrative")
        XCTAssertEqual(try vault.labReport(id: id)?.report.narrative, "LDL is above range; HbA1c is normal.")
    }

    func test_orphan_narrative_is_archived_not_dropped() throws {
        let outcome = try run("bloodworkNarrative")
        guard case .archived(let json) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(json.contains("LDL"))
    }

    func test_website_dexa_fhir_keeps_regional_values() throws {
        let outcome = try run("dexaFhir")
        guard case .imported(_, let id?, _, let note, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(note, "every FHIR value became a marker")
        let report = try XCTUnwrap(try vault.labReport(id: id))
        XCTAssertEqual(report.asDexa.totalBodyFatPercent, 18.4)
        XCTAssertEqual(report.asDexa.visceralFatAreaCm2, 70.1)
        XCTAssertEqual(report.asDexa.boneDensityTotal?.bmd, 1.21)
        let regions = Dictionary(uniqueKeysWithValues: report.dexaRegions.map { ($0.region, $0.markers) })
        XCTAssertEqual(regions["trunk"]?.first { $0.canonicalName == "fat_mass_kg" }?.value, 7.7)
        XCTAssertEqual(regions["trunk"]?.first { $0.canonicalName == "bone_t_score" }?.value, 0.2)
        XCTAssertEqual(regions["left_arm"]?.count, 3)
    }

    func test_same_report_twice_is_a_duplicate() throws {
        try run("bloodworkFhir")
        let c = try fixture("bloodworkFhir")
        let copy = AmachAPIClient.RawStorjObject(key: "bloodwork-report-fhir/1-copy.enc", size: 1, dataType: c.dataType, uploadedAt: c.uploadedAt + 1)
        let outcome = importer.importObject(copy, bytes: Data(c.objectText.utf8), passphrase: passphrase)
        guard case .duplicate = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try vault.labReportCount(), 1)
    }

    // MARK: - Timeline, chat, memory, merkle

    func test_web_timeline_event_and_unknown_type_are_both_kept() throws {
        try run("timelineWeb")
        try run("timelineUnknownType")
        let shown = Dictionary(uniqueKeysWithValues: try vault.timelineEvents().map { ($0.id, $0) })
        XCTAssertEqual(shown["evt-web-1"]?.eventType, .medicationStarted)
        XCTAssertEqual(shown["evt-web-1"]?.data["dose"], "2000")
        XCTAssertEqual(shown["evt-web-1"]?.metadata.source, .userEntered)
        XCTAssertEqual(shown["evt-web-2"]?.eventType, .custom, "unknown types show as Custom, like TimelineEvent decoding")
        let rawType = try vault.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT event_type FROM timeline_events WHERE id = 'evt-web-2'")
        }
        XCTAssertEqual(rawType, "SOMETHING_NEW", "the original type is kept")
        XCTAssertTrue(try status("timelineUnknownType")?.detail?.contains("SOMETHING_NEW") ?? false)

        // Saving from the app again doesn't overwrite the original type.
        try vault.saveTimelineEvents(Array(shown.values), origin: "device")
        let after = try vault.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT event_type FROM timeline_events WHERE id = 'evt-web-2'")
        }
        XCTAssertEqual(after, "SOMETHING_NEW")
    }

    func test_ios_and_web_chat_sessions_import() throws {
        try run("chatSessionIOS")
        try run("conversationSessionWeb")
        let counts = try vault.chatCounts()
        XCTAssertEqual(counts.sessions, 2)
        XCTAssertEqual(counts.messages, 4)
        let ios = try XCTUnwrap(try vault.chatSession(id: UUID(uuidString: "6F1A2B3C-0000-4000-8000-000000000001")!))
        XCTAssertEqual(ios.messages.map(\.content), ["How did I sleep?", "About 7 hours."])
        // Re-importing the same object is a duplicate, not a second copy.
        guard case .duplicate = try run("chatSessionIOS") else { return XCTFail() }
    }

    func test_conversation_memory_merges() throws {
        try run("conversationMemoryIOS")
        let memory = try vault.loadMemory()
        XCTAssertEqual(memory.facts.map(\.value), ["Run a half marathon"])
        XCTAssertEqual(memory.summaries.first?.topics, ["running"])
    }

    func test_merkle_leaves_store_hash_as_hex() throws {
        try run("merkleLeaves")
        let leaf = try XCTUnwrap(try vault.dbQueue.read { db in try MerkleLeafRow.fetchOne(db) })
        XCTAssertEqual(leaf.dayId, 20000)
        XCTAssertEqual(leaf.hash, "0xff")
        XCTAssertTrue(leaf.fields.contains("\"steps\":9000"))
    }

    // MARK: - Failures

    func test_wrong_key_is_recorded_as_failed_with_reason() throws {
        let c = try fixture("timelineWeb")
        let outcome = importer.importObject(object(c), bytes: Data(c.objectText.utf8), passphrase: String(repeating: "1", count: 64))
        importer.recordStatus(outcome, object: object(c))
        guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.hasPrefix("Decrypt failed"))
        XCTAssertEqual(try status("timelineWeb")?.status, "failed")
    }

    func test_unrecognized_shape_under_a_report_dataType_is_kept_as_json() throws {
        // Routing goes by the JSON's shape: a non-report under a report
        // dataType is archived with its contents, never dropped.
        let c = try fixture("healthScores")
        let odd = AmachAPIClient.RawStorjObject(key: "bloodwork-report-fhir/2-odd.enc", size: 1, dataType: "bloodwork-report-fhir", uploadedAt: 2)
        guard case .archived(let json) = importer.importObject(odd, bytes: Data(c.objectText.utf8), passphrase: passphrase) else {
            return XCTFail()
        }
        XCTAssertTrue(json.contains("overall"))
    }

    func test_unit_conversion_for_sample_exports() {
        XCTAssertEqual(StorjObjectImporter.convert(5.2, from: "km", to: "m"), 5200)
        XCTAssertEqual(StorjObjectImporter.convert(10, from: "hr", to: "min"), 600)
        XCTAssertEqual(StorjObjectImporter.convert(0.97, from: "%", to: "%") ?? 0, 97, accuracy: 1e-9)
        XCTAssertEqual(StorjObjectImporter.convert(97.8, from: "%", to: "%"), 97.8)
        XCTAssertEqual(StorjObjectImporter.convert(38.5, from: "mL/kg·min", to: "mL/kg/min"), 38.5)
        XCTAssertEqual(StorjObjectImporter.convert(22, from: "kg/m²", to: "kg/m2"), 22)
        XCTAssertEqual(StorjObjectImporter.convert(212, from: "degF", to: "degC") ?? 0, 100, accuracy: 1e-9)
        XCTAssertNil(StorjObjectImporter.convert(1, from: "furlong", to: "m"))
    }

    // MARK: - Helpers

    func test_decimal_to_hex_handles_poseidon_sized_numbers() {
        XCTAssertEqual(StorjObjectImporter.decimalToHex("0"), "0x0")
        XCTAssertEqual(StorjObjectImporter.decimalToHex("255"), "0xff")
        XCTAssertEqual(
            StorjObjectImporter.decimalToHex("21888242871839275222246405745257275088548364400416034343698204186575808495617"),
            "0x30644e72e131a029b85045b68181585d2833e84879b9709143e1f593f0000001"
        )
    }

    func test_uuid_from_non_uuid_id_is_stable() {
        XCTAssertEqual(StorjObjectImporter.uuid(from: "web-session-1"), StorjObjectImporter.uuid(from: "web-session-1"))
        XCTAssertNotEqual(StorjObjectImporter.uuid(from: "a"), StorjObjectImporter.uuid(from: "b"))
        let real = UUID()
        XCTAssertEqual(StorjObjectImporter.uuid(from: real.uuidString), real)
    }
}
