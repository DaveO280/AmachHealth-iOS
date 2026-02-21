// AppStateTests.swift
// AmachHealthTests
//
// Tests for AppState: computed properties, state mutations,
// UserDefaults persistence.
//
// All tests run without a Simulator — AppState is pure Swift
// (@Observable, no UIKit/HealthKit dependencies at init time).

import XCTest
@testable import AmachHealth


// ============================================================
// MARK: - isFullyConnected
// ============================================================

final class AppStateConnectivityTests: XCTestCase {

    func test_isFullyConnected_false_when_both_disconnected() {
        let state = AppState()
        state.isHealthKitAuthorized = false
        state.isWalletConnected = false
        XCTAssertFalse(state.isFullyConnected)
    }

    func test_isFullyConnected_false_when_only_healthkit() {
        let state = AppState()
        state.isHealthKitAuthorized = true
        state.isWalletConnected = false
        XCTAssertFalse(state.isFullyConnected)
    }

    func test_isFullyConnected_false_when_only_wallet() {
        let state = AppState()
        state.isHealthKitAuthorized = false
        state.isWalletConnected = true
        XCTAssertFalse(state.isFullyConnected)
    }

    func test_isFullyConnected_true_when_both_connected() {
        let state = AppState()
        state.isHealthKitAuthorized = true
        state.isWalletConnected = true
        XCTAssertTrue(state.isFullyConnected)
    }
}


// ============================================================
// MARK: - tierDisplayName
// ============================================================

final class AppStateTierDisplayNameTests: XCTestCase {

    func test_gold_display_name() {
        let state = AppState()
        state.currentTier = "GOLD"
        XCTAssertEqual(state.tierDisplayName, "Gold")
    }

    func test_silver_display_name() {
        let state = AppState()
        state.currentTier = "SILVER"
        XCTAssertEqual(state.tierDisplayName, "Silver")
    }

    func test_bronze_display_name() {
        let state = AppState()
        state.currentTier = "BRONZE"
        XCTAssertEqual(state.tierDisplayName, "Bronze")
    }

    func test_none_display_name() {
        let state = AppState()
        state.currentTier = "NONE"
        XCTAssertEqual(state.tierDisplayName, "No Tier")
    }

    func test_empty_string_falls_through_to_no_tier() {
        let state = AppState()
        state.currentTier = ""
        XCTAssertEqual(state.tierDisplayName, "No Tier")
    }

    func test_lowercase_tier_is_uppercased_before_comparison() {
        let state = AppState()
        state.currentTier = "gold"
        XCTAssertEqual(state.tierDisplayName, "Gold")
    }

    func test_mixed_case_tier_is_normalized() {
        let state = AppState()
        state.currentTier = "Silver"
        XCTAssertEqual(state.tierDisplayName, "Silver")
    }
}


// ============================================================
// MARK: - recordSync()
// ============================================================

final class AppStateRecordSyncTests: XCTestCase {

    func test_recordSync_updates_tier_and_score() {
        let state = AppState()
        state.recordSync(tier: "GOLD", score: 85)
        XCTAssertEqual(state.currentTier, "GOLD")
        XCTAssertEqual(state.dataScore, 85)
    }

    func test_recordSync_stores_provided_date() {
        let state = AppState()
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        state.recordSync(tier: "SILVER", score: 65, date: d)
        XCTAssertEqual(state.lastSyncDate, d)
    }

    func test_recordSync_defaults_date_to_now() {
        let state = AppState()
        let before = Date()
        state.recordSync(tier: "BRONZE", score: 42)
        let after = Date()
        let syncDate = try! XCTUnwrap(state.lastSyncDate)
        XCTAssertGreaterThanOrEqual(syncDate, before)
        XCTAssertLessThanOrEqual(syncDate, after)
    }

    func test_recordSync_can_downgrade_tier() {
        let state = AppState()
        state.recordSync(tier: "GOLD", score: 90)
        state.recordSync(tier: "BRONZE", score: 41)
        XCTAssertEqual(state.currentTier, "BRONZE")
        XCTAssertEqual(state.dataScore, 41)
    }
}


// ============================================================
// MARK: - setWallet()
// ============================================================

final class AppStateSetWalletTests: XCTestCase {

    func test_setWallet_with_address_connects() {
        let state = AppState()
        state.setWallet(address: "0xDeadBeef")
        XCTAssertEqual(state.walletAddress, "0xDeadBeef")
        XCTAssertTrue(state.isWalletConnected)
        XCTAssertTrue(state.isAuthenticated)
    }

    func test_setWallet_with_nil_disconnects() {
        let state = AppState()
        state.setWallet(address: "0xDeadBeef") // first connect
        state.setWallet(address: nil)           // then disconnect
        XCTAssertNil(state.walletAddress)
        XCTAssertFalse(state.isWalletConnected)
        XCTAssertFalse(state.isAuthenticated)
    }

    func test_setWallet_updates_isAuthenticated_atomically() {
        // isAuthenticated and isWalletConnected must agree at all times
        let state = AppState()
        state.setWallet(address: "0x123")
        XCTAssertEqual(state.isAuthenticated, state.isWalletConnected)

        state.setWallet(address: nil)
        XCTAssertEqual(state.isAuthenticated, state.isWalletConnected)
    }
}


// ============================================================
// MARK: - setHealthKit()
// ============================================================

final class AppStateSetHealthKitTests: XCTestCase {

    func test_setHealthKit_authorized_true() {
        let state = AppState()
        state.setHealthKit(authorized: true)
        XCTAssertTrue(state.isHealthKitAuthorized)
    }

    func test_setHealthKit_authorized_false() {
        let state = AppState()
        state.setHealthKit(authorized: true)
        state.setHealthKit(authorized: false)
        XCTAssertFalse(state.isHealthKitAuthorized)
    }
}


// ============================================================
// MARK: - toast()
// ============================================================

final class AppStateToastTests: XCTestCase {

    func test_toast_sets_currentToast() {
        let state = AppState()
        let t = AmachToast.success("Sync complete")
        state.toast(t)
        XCTAssertEqual(state.currentToast?.message, "Sync complete")
        XCTAssertEqual(state.currentToast?.style, .success)
    }

    func test_currentToast_starts_nil() {
        let state = AppState()
        XCTAssertNil(state.currentToast)
    }
}


// ============================================================
// MARK: - onboardingComplete (UserDefaults)
// ============================================================

final class AppStateOnboardingTests: XCTestCase {

    private let key = "amach.onboardingComplete"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func test_defaults_to_false_when_key_absent() {
        let state = AppState()
        XCTAssertFalse(state.onboardingComplete)
    }

    func test_setting_true_persists_to_userdefaults() {
        let state = AppState()
        state.onboardingComplete = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))
    }

    func test_setting_false_persists_to_userdefaults() {
        UserDefaults.standard.set(true, forKey: key) // pre-seed
        let state = AppState()
        state.onboardingComplete = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
    }

    func test_new_instance_reads_existing_userdefaults_value() {
        UserDefaults.standard.set(true, forKey: key)
        let state = AppState()
        XCTAssertTrue(state.onboardingComplete)
    }
}


// ============================================================
// MARK: - Preview State Snapshot
// ============================================================

final class AppStatePreviewTests: XCTestCase {

    func test_preview_state_is_fully_connected() {
        let state = AppState.preview
        XCTAssertTrue(state.isFullyConnected)
    }

    func test_preview_state_has_gold_tier() {
        let state = AppState.preview
        XCTAssertEqual(state.tierDisplayName, "Gold")
    }

    func test_preview_state_is_authenticated() {
        let state = AppState.preview
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertNotNil(state.walletAddress)
    }

    func test_preview_state_has_positive_score() {
        let state = AppState.preview
        XCTAssertGreaterThan(state.dataScore, 0)
    }
}
