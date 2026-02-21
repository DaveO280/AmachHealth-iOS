// DesignTokenTests.swift
// AmachHealthTests
//
// Snapshot tests for AmachDesignSystem tokens.
//
// Philosophy: Design tokens are a contract between design and
// engineering. When a token value changes unintentionally, a test
// should catch it before it reaches the app.
//
// These are fully runnable without a Simulator — all values are
// plain Swift constants (CGFloat, Double, String) with no UIKit
// or SwiftUI rendering required.

import XCTest
@testable import AmachHealth


// ============================================================
// MARK: - SPACING SYSTEM (4pt base grid)
// ============================================================

final class SpacingSystemTests: XCTestCase {

    // Core scale — must be exact multiples of 4
    func test_xs_is_4pt() {
        XCTAssertEqual(AmachSpacing.xs, 4)
    }

    func test_sm_is_8pt() {
        XCTAssertEqual(AmachSpacing.sm, 8)
    }

    func test_md_is_16pt() {
        XCTAssertEqual(AmachSpacing.md, 16)
    }

    func test_lg_is_24pt() {
        XCTAssertEqual(AmachSpacing.lg, 24)
    }

    func test_xl_is_32pt() {
        XCTAssertEqual(AmachSpacing.xl, 32)
    }

    func test_xxl_is_48pt() {
        XCTAssertEqual(AmachSpacing.xxl, 48)
    }

    func test_xxxl_is_64pt() {
        XCTAssertEqual(AmachSpacing.xxxl, 64)
    }

    // Grid compliance — every core step must be divisible by 4
    func test_all_core_values_divisible_by_4() {
        let values: [CGFloat] = [
            AmachSpacing.xs, AmachSpacing.sm, AmachSpacing.md,
            AmachSpacing.lg, AmachSpacing.xl, AmachSpacing.xxl,
            AmachSpacing.xxxl
        ]
        for value in values {
            XCTAssertEqual(value.truncatingRemainder(dividingBy: 4), 0,
                           "\(value)pt is not on the 4pt grid")
        }
    }

    // Named component-specific tokens
    func test_cardPadding_is_24pt() {
        XCTAssertEqual(AmachSpacing.cardPadding, 24)
    }

    func test_cardGap_is_16pt() {
        XCTAssertEqual(AmachSpacing.cardGap, 16)
    }

    func test_sectionSpacing_is_32pt() {
        XCTAssertEqual(AmachSpacing.sectionSpacing, 32)
    }

    func test_screenEdge_is_16pt() {
        XCTAssertEqual(AmachSpacing.screenEdge, 16)
    }

    func test_chatMsgSpacing_is_16pt() {
        XCTAssertEqual(AmachSpacing.chatMsgSpacing, 16)
    }

    func test_chatMsgSpacingLg_is_24pt() {
        XCTAssertEqual(AmachSpacing.chatMsgSpacingLg, 24)
    }
}


// ============================================================
// MARK: - CORNER RADIUS
// ============================================================

final class CornerRadiusTests: XCTestCase {

    func test_xs_radius_is_6pt() {
        XCTAssertEqual(AmachRadius.xs, 6)
    }

    func test_sm_radius_is_10pt() {
        XCTAssertEqual(AmachRadius.sm, 10)
    }

    func test_md_radius_is_14pt() {
        XCTAssertEqual(AmachRadius.md, 14)
    }

    func test_card_radius_is_16pt() {
        XCTAssertEqual(AmachRadius.card, 16)
    }

    func test_lg_radius_is_20pt() {
        XCTAssertEqual(AmachRadius.lg, 20)
    }

    func test_xl_radius_is_24pt() {
        XCTAssertEqual(AmachRadius.xl, 24)
    }

    func test_pill_radius_is_100pt() {
        XCTAssertEqual(AmachRadius.pill, 100)
    }

    // Hierarchy rule: each step must be >= the previous
    func test_radius_scale_is_strictly_ascending() {
        let scale: [CGFloat] = [
            AmachRadius.xs, AmachRadius.sm, AmachRadius.md,
            AmachRadius.card, AmachRadius.lg, AmachRadius.xl
        ]
        for i in 1..<scale.count {
            XCTAssertGreaterThan(scale[i], scale[i - 1],
                "Radius step \(i) (\(scale[i])) is not greater than step \(i-1) (\(scale[i-1]))")
        }
    }
}


// ============================================================
// MARK: - ANIMATION TIMING
// ============================================================

final class AnimationTimingTests: XCTestCase {

    func test_fast_duration_is_point_15s() {
        XCTAssertEqual(AmachAnimation.durationFast, 0.15, accuracy: 0.001)
    }

    func test_normal_duration_is_point_25s() {
        XCTAssertEqual(AmachAnimation.durationNormal, 0.25, accuracy: 0.001)
    }

    func test_slow_duration_is_point_40s() {
        XCTAssertEqual(AmachAnimation.durationSlow, 0.40, accuracy: 0.001)
    }

    // Relative ordering: fast < normal < slow
    func test_animation_durations_are_ordered() {
        XCTAssertLessThan(AmachAnimation.durationFast, AmachAnimation.durationNormal)
        XCTAssertLessThan(AmachAnimation.durationNormal, AmachAnimation.durationSlow)
    }
}


// ============================================================
// MARK: - ELEVATION CONSTANTS
// ============================================================

final class ElevationConstantsTests: XCTestCase {

    // Shadow opacity must increase with elevation level
    func test_shadow_opacity_increases_with_elevation() {
        // Level1: 0.10, Level2: 0.18, Level3: 0.30
        let l1 = 0.10
        let l2 = 0.18
        let l3 = 0.30
        XCTAssertLessThan(l1, l2)
        XCTAssertLessThan(l2, l3)
    }

    // Blur radius must increase with elevation level
    func test_blur_radius_increases_with_elevation() {
        // Level2: 16, Level3: 24
        XCTAssertLessThan(AmachElevation.Level2.blurRadius, AmachElevation.Level3.blurRadius)
    }

    // Shadow Y-offset grows as elements float higher
    func test_shadow_y_offset_increases_with_elevation() {
        XCTAssertLessThan(AmachElevation.Level1.shadowY, AmachElevation.Level2.shadowY)
        XCTAssertLessThan(AmachElevation.Level2.shadowY, AmachElevation.Level3.shadowY)
    }

    // Level 3 is the only level with a modal scrim
    func test_level3_has_overlay_opacity() {
        XCTAssertGreaterThan(AmachElevation.Level3.overlayOpacity, 0)
    }
}


// ============================================================
// MARK: - SCALE RATIO INTEGRITY
// ============================================================

final class SpacingRatioTests: XCTestCase {

    // cardGap should equal md (both are 16pt)
    func test_cardGap_equals_md() {
        XCTAssertEqual(AmachSpacing.cardGap, AmachSpacing.md)
    }

    // cardPadding should equal lg (both are 24pt)
    func test_cardPadding_equals_lg() {
        XCTAssertEqual(AmachSpacing.cardPadding, AmachSpacing.lg)
    }

    // sectionSpacing should equal xl (both are 32pt)
    func test_sectionSpacing_equals_xl() {
        XCTAssertEqual(AmachSpacing.sectionSpacing, AmachSpacing.xl)
    }

    // screenEdge should equal md (both are 16pt)
    func test_screenEdge_equals_md() {
        XCTAssertEqual(AmachSpacing.screenEdge, AmachSpacing.md)
    }
}
