// AmachDesignSystem.swift
// Amach Health — Single source of truth for all design tokens
//
// Architecture: Senior Design Systems / Apple HIG
// Philosophy: "Earthy palette, modern execution"
//   Principles: Clarity Over Cleverness · Your Data, Your Health
//               Driven by Data, Guided by Nature
//
// HOW TO USE:
//   Colors:     Color.Amach.primary, Color.Amach.AI.base
//   Type:       AmachType.h1, AmachType.dataValue(size: 36)
//   Spacing:    AmachSpacing.md (16), AmachSpacing.lg (24)
//   Radius:     AmachRadius.card (16), AmachRadius.bubble (20)
//   Elevation:  AmachElevation.Level1.shadowColor, etc.
//   Animation:  AmachAnimation.spring, AmachAnimation.normal
//   Haptics:    AmachHaptics.cardTap(), AmachHaptics.success()
//   Modifiers:  .amachCard(), .amachCardElevated(), .amachAIBorder()

import SwiftUI

// ============================================================
// MARK: - COLOR SYSTEM
// ============================================================

extension Color {

    enum Amach {

        // ──────────────────────────────────────────────────────
        // Primary — Earthy Emerald
        // Brand anchor. Deep, grounded, not clinical.
        //
        // DO NOT use primary as large background fill — it is a
        // signal color, not a surface color.
        //
        // primary    → CTAs, active states, focus rings, icons
        // primaryDark→ pressed states, dark mode emphasis text
        // p400       → the legible dark-mode variant (use when
        //              #006B4F fails contrast on dark surface)
        // p200/p100  → badge fills, subtle background tints
        // ──────────────────────────────────────────────────────
        static let primary      = Color(hex: "006B4F") // earthy emerald — brand anchor
        static let primaryDark  = Color(hex: "004D38") // pressed / dark emphasis
        static let p700         = Color(hex: "005941") // between primary and dark
        static let p500         = Color(hex: "008C66") // slightly brighter
        static let p400         = Color(hex: "10B981") // emerald-400 — dark mode legibility
        static let p300         = Color(hex: "34D399") // emerald-300 — vibrant on dark
        static let p200         = Color(hex: "6EE7B7") // emerald-200 — subtle tints
        static let p100         = Color(hex: "D1FAE5") // emerald-100 — badge fills
        static let p50          = Color(hex: "ECFDF5") // emerald-50  — page-level tint

        // ──────────────────────────────────────────────────────
        // Accent — Amber
        // Energy, warmth, attention. Use sparingly.
        // One amber element per screen maximum.
        //
        // accent → tier gold badge, featured card accent, CTA ring
        // a600   → text on light amber backgrounds (WCAG AA)
        // a100   → badge/card background fill
        //
        // When amber signals WARNING, always pair with a label or
        // ⚠ icon — never rely on color alone for semantic meaning.
        // ──────────────────────────────────────────────────────
        static let accent = Color(hex: "F59E0B") // amber-500
        static let a600   = Color(hex: "D97706") // amber-600 — text on light bg
        static let a100   = Color(hex: "FEF3C7") // amber-100 — fill

        // ──────────────────────────────────────────────────────
        // AI Secondary — Soft Indigo (Luma's color)
        //
        // DECISION: Soft Indigo (#6366F1) over slate-blue / cool-teal
        //   ✓ Cognitively associated with intelligence / AI
        //   ✓ Far enough from emerald-green on the color wheel —
        //     distinct without clashing
        //   ✓ Cool without being cold; avoids sterile pure-blue feel
        //   ✓ Warm/cool contrast (emerald vs indigo) immediately
        //     signals user context vs Luma context in chat
        //
        // PROTECTION: indigo = Luma. Only apply to AI-generated
        // content. Never use on user or system elements.
        // ──────────────────────────────────────────────────────
        enum AI {
            static let base  = Color(hex: "6366F1") // indigo-500 — Luma primary
            static let light = Color(hex: "EEF2FF") // indigo-50  — light mode bubble bg
            static let dark  = Color(hex: "3730A3") // indigo-800 — dark mode bubble bg
            static let p400  = Color(hex: "818CF8") // indigo-400 — dark mode legibility
            static let p200  = Color(hex: "C7D2FE") // indigo-200 — gradient border, tints
        }

        // ──────────────────────────────────────────────────────
        // Semantic Colors
        //
        // Success  → #10B981 (emerald-400 — distinguishable from
        //            brand primary #006B4F because primary is much
        //            darker; on dark surfaces, success reads brighter)
        // Warning  → #F59E0B (shared with Accent; context
        //            disambiguates — always add label for warning use)
        // Error    → #EF4444 — unambiguous, not alarmist
        // Info     → #3B82F6 — neutral, educational overlays
        //
        // Each has .bg / .text / .border for both light and dark.
        // ──────────────────────────────────────────────────────
        enum Semantic {
            static let success        = Color(hex: "10B981")
            static let successBgL     = Color(hex: "ECFDF5")
            static let successBgD     = Color(hex: "064E3B")
            static let successTextL   = Color(hex: "065F46") // 4.6:1 on successBgL
            static let successTextD   = Color(hex: "6EE7B7")
            static let successBorder  = Color(hex: "6EE7B7")

            static let warning        = Color(hex: "F59E0B")
            static let warningBgL     = Color(hex: "FFFBEB")
            static let warningBgD     = Color(hex: "78350F")
            static let warningTextL   = Color(hex: "92400E") // 4.8:1 on warningBgL
            static let warningTextD   = Color(hex: "FCD34D")
            static let warningBorder  = Color(hex: "FCD34D")

            static let error          = Color(hex: "EF4444")
            static let errorBgL       = Color(hex: "FEF2F2")
            static let errorBgD       = Color(hex: "7F1D1D")
            static let errorTextL     = Color(hex: "991B1B") // 5.1:1 on errorBgL
            static let errorTextD     = Color(hex: "FCA5A5")
            static let errorBorder    = Color(hex: "FCA5A5")

            static let info           = Color(hex: "3B82F6")
            static let infoBgL        = Color(hex: "EFF6FF")
            static let infoBgD        = Color(hex: "1E3A5F")
            static let infoTextL      = Color(hex: "1D4ED8") // 4.5:1 on infoBgL
            static let infoTextD      = Color(hex: "93C5FD")
            static let infoBorder     = Color(hex: "93C5FD")
        }

        // ──────────────────────────────────────────────────────
        // Health Metric Status Colors
        //
        // Separate from semantic colors. Optimal/Borderline/Critical
        // communicate position within a range — not pass/fail.
        // Framing principle: "Your Data, Your Health."
        //
        // Used as: chart fill, pill background, text, icon tint.
        // Chart fills: use at 60% opacity on dark surfaces.
        // ──────────────────────────────────────────────────────
        enum Health {
            static let optimal         = Color(hex: "059669") // emerald-600 (≠ p400)
            static let optimalBgL      = Color(hex: "ECFDF5")
            static let optimalBgD      = Color(hex: "064E3B")
            static let optimalTextL    = Color(hex: "047857") // 4.6:1 on optimalBgL
            static let optimalTextD    = Color(hex: "34D399")

            static let borderline      = Color(hex: "D97706") // amber-600 (≠ accent)
            static let borderlineBgL   = Color(hex: "FFFBEB")
            static let borderlineBgD   = Color(hex: "451A03")
            static let borderlineTextL = Color(hex: "92400E") // 4.8:1 on borderlineBgL
            static let borderlineTextD = Color(hex: "FCD34D")

            static let critical        = Color(hex: "DC2626") // red-600
            static let criticalBgL     = Color(hex: "FEF2F2")
            static let criticalBgD     = Color(hex: "450A0A")
            static let criticalTextL   = Color(hex: "991B1B") // 5.1:1 on criticalBgL
            static let criticalTextD   = Color(hex: "FCA5A5")

            static let noData          = Color(hex: "9CA3AF")
            static let noDataBgL       = Color(hex: "F3F4F6")
            static let noDataBgD       = Color(hex: "1F2937")
            static let noDataTextL     = Color(hex: "6B7280") // 4.5:1 on white
            static let noDataTextD     = Color(hex: "9CA3AF")
        }

        // ──────────────────────────────────────────────────────
        // Tier Colors
        //
        // Data quality tiers: Gold > Silver > Bronze > None.
        // Used for: TierBadge, attestation cards, sync result.
        //
        // Colors echo real-world materials (warm gold, cool silver,
        // earthy bronze) — grounded, not gamified.
        //
        // Always use the BG/Text/Border triplet together.
        // Never use tier colors for health status.
        // ──────────────────────────────────────────────────────
        enum Tier {
            static let goldBg      = Color(hex: "FEF3C7")
            static let goldText    = Color(hex: "B45309") // 4.7:1 on goldBg
            static let goldBorder  = Color(hex: "FCD34D")

            static let silverBg     = Color(hex: "F1F5F9")
            static let silverText   = Color(hex: "475569") // 5.0:1 on silverBg
            static let silverBorder = Color(hex: "CBD5E1")

            static let bronzeBg     = Color(hex: "FDF0E6")
            static let bronzeText   = Color(hex: "9A4B1C") // 4.9:1 on bronzeBg
            static let bronzeBorder = Color(hex: "E8A87C")

            static let noneBg     = Color(hex: "F3F4F6")
            static let noneText   = Color(hex: "6B7280") // 4.5:1 on noneBg
            static let noneBorder = Color(hex: "D1D5DB")
        }

        // ──────────────────────────────────────────────────────
        // Surface Colors — Three Elevation Levels
        //
        // Dark mode backgrounds are GREEN-TINTED — hard brand
        // requirement. Hue ~155°, subtle but present, connects
        // to the emerald primary. NOT generic dark gray/navy.
        //
        // Elevation metaphor:
        //   bg       → the floor (behind everything)
        //   surface  → table (cards, list rows)
        //   elevated → raised platform (featured cards, FAB)
        // ──────────────────────────────────────────────────────
        enum Surface {
            static let bgLight       = Color(hex: "FFFFFF")
            static let surfaceLight  = Color(hex: "F9FAFB")
            static let elevatedLight = Color(hex: "F3F4F6")

            // Green-tinted dark — NOT navy, NOT generic dark gray
            static let bgDark       = Color(hex: "0A1A15")
            static let surfaceDark  = Color(hex: "111F1A")
            static let elevatedDark = Color(hex: "1A2E26")
        }

        // ──────────────────────────────────────────────────────
        // Text Colors
        //
        // Hierarchy matters. Not everything should be primary text.
        // Using secondary/tertiary reduces cognitive load and creates
        // the visual rhythm that makes premium apps feel calm.
        //
        // primary   → titles, key data values, headings
        // secondary → body text, descriptions, supporting info
        // tertiary  → timestamps, placeholders (use at 14pt+ only)
        // onPrimary → on primary-colored surfaces (#FFFFFF)
        // onAccent  → on amber surfaces (dark amber, not white)
        // ──────────────────────────────────────────────────────
        enum Text {
            static let primaryL   = Color(hex: "111827") // gray-900  15.3:1 on white
            static let secondaryL = Color(hex: "6B7280") // gray-500   4.5:1 on white
            static let tertiaryL  = Color(hex: "9CA3AF") // gray-400   3.0:1 (14pt+ only)

            static let primaryD   = Color(hex: "F9FAFB") // gray-50   17.2:1 on bgDark
            static let secondaryD = Color(hex: "9CA3AF") // gray-400   7.4:1 on surfaceDark
            static let tertiaryD  = Color(hex: "6B7280") // gray-500   4.5:1 on surfaceDark

            static let onPrimary  = Color(hex: "FFFFFF") // 7.0:1 on #006B4F
            static let onAccent   = Color(hex: "451A03") // 4.9:1 on #F59E0B
            static let onAI       = Color(hex: "FFFFFF") // 8.1:1 on AI.dark
        }
    }
}

// ── Hex Initializer ──────────────────────────────────────────
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var n: UInt64 = 0
        Scanner(string: h).scanHexInt64(&n)
        let a, r, g, b: UInt64
        switch h.count {
        case 3:  (a,r,g,b) = (255,(n>>8)*17,(n>>4 & 0xF)*17,(n & 0xF)*17)
        case 6:  (a,r,g,b) = (255,n>>16,n>>8 & 0xFF,n & 0xFF)
        case 8:  (a,r,g,b) = (n>>24,n>>16 & 0xFF,n>>8 & 0xFF,n & 0xFF)
        default: (a,r,g,b) = (255,0,0,0)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255,
                  blue: Double(b)/255, opacity: Double(a)/255)
    }
}


// ============================================================
// MARK: - TYPOGRAPHY SYSTEM
// ============================================================

/// Type scale: SF Pro (iOS primary) / Inter (web fallback).
/// Data/numbers: SF Mono — used ONLY for biomarker values,
/// metric numbers, hash previews. Never for prose.
///
/// H3 and Body are both 16pt — differentiated by weight only.
/// This is intentional: reduces visual noise while maintaining
/// hierarchy. The difference is felt, not calculated.
///
/// DataValue + DataUnit pairing rule:
///   Value: SF Mono Bold, contextual size (24–48pt)
///   Unit:  Regular (not mono), ~65% of value size, secondary color
///   e.g. "142" (28pt Mono Bold) + "mg/dL" (18pt Regular, gray)

enum AmachType {
    /// 28pt Bold — page titles only
    static var h1: Font { .system(size: 28, weight: .bold) }

    /// 20pt Semibold — section headers, modal titles
    static var h2: Font { .system(size: 20, weight: .semibold) }

    /// 16pt Semibold — card titles (same size as body; weight = hierarchy)
    static var h3: Font { .system(size: 16, weight: .semibold) }

    /// 16pt Regular — all body text, Luma chat messages, user messages
    static var body: Font { .system(size: 16, weight: .regular) }

    /// 14pt Regular — secondary info, card subtitles, descriptions
    static var caption: Font { .system(size: 14, weight: .regular) }

    /// 12pt Medium — timestamps, badges, tier labels (always uppercase)
    static var tiny: Font { .system(size: 12, weight: .medium) }

    /// SF Mono Bold — biomarker numbers, scores, metric values
    static func dataValue(size: CGFloat = 28) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }

    /// SF Mono Regular — unit labels alongside values
    static func dataUnit(size: CGFloat = 18) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// SF Mono Medium — hash previews, on-chain addresses
    static var dataMono: Font { .system(size: 12, weight: .medium, design: .monospaced) }
}

// Line height reference (use .lineSpacing() in SwiftUI):
//   h1:      lineSpacing(6)   → ~34pt total
//   h2:      lineSpacing(6)   → ~26pt total
//   body:    lineSpacing(8)   → ~24pt total (generous 1.5x — builds trust)
//   caption: lineSpacing(6)   → ~20pt total
//   tiny:    lineSpacing(4)   → ~16pt total
// Letter spacing (use .tracking()):
//   h1: -0.3 · h2: -0.2 · h3: -0.1 · tiny: +0.2 · all others: 0


// ============================================================
// MARK: - SPACING SYSTEM
// ============================================================

/// 4pt base grid. Never hardcode spacing values in views.
/// Philosophy: generous. Consumer health, not clinical portal.
/// Breathing room builds trust.

enum AmachSpacing {
    static let xs:   CGFloat = 4    // tight inline (icon-to-label)
    static let sm:   CGFloat = 8    // related elements (badge-to-text)
    static let md:   CGFloat = 16   // standard padding, screen edge
    static let lg:   CGFloat = 24   // card internal padding, sub-sections
    static let xl:   CGFloat = 32   // between major sections
    static let xxl:  CGFloat = 48   // feature spacing, hero
    static let xxxl: CGFloat = 64   // screen-level spacers

    // Component-specific (fixed — do not scale with Dynamic Type)
    static let cardPadding:      CGFloat = 24
    static let cardGap:          CGFloat = 16
    static let sectionSpacing:   CGFloat = 32
    static let screenEdge:       CGFloat = 16
    static let chatMsgSpacing:   CGFloat = 16   // between same-role messages
    static let chatMsgSpacingLg: CGFloat = 24   // after role-change

    // System chrome
    static let tabBarHeight:     CGFloat = 83   // 49 bar + 34 home indicator
    static let statusBarClear:   CGFloat = 59   // Dynamic Island (iPhone Pro)
    static let navBarHeight:     CGFloat = 44
}


// ============================================================
// MARK: - CORNER RADIUS
// ============================================================

/// Larger surfaces → larger radius. Cards rounder than buttons.
/// Never mix radius values within the same component.

enum AmachRadius {
    static let xs:   CGFloat = 6    // badges, tier pills
    static let sm:   CGFloat = 10   // secondary buttons, inputs
    static let md:   CGFloat = 14   // primary buttons, toolbar
    static let card: CGFloat = 16   // all standard cards
    static let lg:   CGFloat = 20   // chat bubbles, featured cards
    static let xl:   CGFloat = 24   // modal corners, bottom sheets
    static let pill: CGFloat = 100  // fully rounded (progress bars)
}


// ============================================================
// MARK: - ELEVATION & DEPTH SYSTEM
// ============================================================

enum AmachElevation {

    /// Level 1 — Base: cards, list rows, standard surfaces.
    /// No glassmorphism. Solid surface color with subtle border.
    struct Level1 {
        static let shadowColor    = Color.black.opacity(0.10)
        static let shadowRadius:  CGFloat = 8
        static let shadowX:       CGFloat = 0
        static let shadowY:       CGFloat = 2
        static let borderOpacity: Double  = 0.12
    }

    /// Level 2 — Raised: featured cards, Luma FAB, active states.
    /// Glass treatment: blur 16, bg 70% opacity.
    struct Level2 {
        static let shadowColor    = Color.black.opacity(0.18)
        static let shadowRadius:  CGFloat = 16
        static let shadowX:       CGFloat = 0
        static let shadowY:       CGFloat = 6
        static let blurRadius:    CGFloat = 16
        static let bgOpacity:     Double  = 0.70
        static let borderOpacity: Double  = 0.20
    }

    /// Level 3 — Floating: modals, Luma half-sheet, toasts.
    /// Glass: blur 24, bg 88%. Scrim: black 40% behind.
    struct Level3 {
        static let shadowColor     = Color.black.opacity(0.30)
        static let shadowRadius:   CGFloat = 32
        static let shadowX:        CGFloat = 0
        static let shadowY:        CGFloat = 16
        static let blurRadius:     CGFloat = 24
        static let bgOpacity:      Double  = 0.88
        static let overlayOpacity: Double  = 0.40
    }
}

// Glass vs Solid usage rules:
//   Glass ✓  Level 2+ in dark mode, Luma sheet, tab bar (dark)
//   Glass ✗  Level 1 cards (too heavy), text-over-complex-bg
//   Solid ✓  MetricCard, list rows, all light mode cards
//
// Gradient border (primary → AI.base, 135°, 1pt):
//   ✓ Luma insight / AI-analyzed cards only
//   ✗ Never on user content, navigation, standard cards


// ============================================================
// MARK: - ANIMATION & MOTION SYSTEM
// ============================================================

/// All timing and easing tokens. Import and use — no hardcoded
/// durations in view code.
///
/// Reduce Motion is a hard requirement. Check
/// UIAccessibility.isReduceMotionEnabled before complex motion.

enum AmachAnimation {
    // Timing
    static let durationFast:    Double = 0.15  // toggles, micro-interactions
    static let durationNormal:  Double = 0.25  // state changes, card transitions
    static let durationSlow:    Double = 0.40  // page transitions
    static let durationChart:   Double = 0.80  // chart line draw
    static let durationCount:   Double = 0.50  // number count-up
    static let durationShimmer: Double = 1.50  // skeleton pulse
    static let durationToastVisible: Double = 3.0

    // Animations
    static let fast:        Animation = .easeOut(duration: durationFast)
    static let normal:      Animation = .easeOut(duration: durationNormal)
    static let slow:        Animation = .easeInOut(duration: durationSlow)
    static let spring:      Animation = .spring(response: 0.3, dampingFraction: 0.7)
    static let sheetSpring: Animation = .spring(response: 0.35, dampingFraction: 0.85)
    static let countUp:     Animation = .easeOut(duration: durationCount)
    static let chartDraw:   Animation = .easeInOut(duration: durationChart)
    static let toastAppear: Animation = .spring(response: 0.3, dampingFraction: 0.85)
    static let toastDismiss: Animation = .easeIn(duration: 0.20)

    // Scale effects
    static let cardPressScale:   CGFloat = 0.97
    static let buttonPressScale: CGFloat = 0.96

    // Luma typing indicator: stagger 150ms per dot, bounce 600ms, repeat
    static let lumaTypingDotDuration: Double = 0.6
    static let lumaTypingStagger:     Double = 0.15

    /// Returns nil when Reduce Motion is enabled — collapses to instant.
    static func ifMotion(_ animation: Animation) -> Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : animation
    }
}


// ============================================================
// MARK: - HAPTIC FEEDBACK
// ============================================================

// Haptic map:
//   cardTap()     → .light   — card selection, list row tap
//   buttonPress() → .medium  — primary action buttons
//   success()     → .success — sync complete, upload done
//   error()       → .error   — sync fail, auth error
//   toggle()      → .selection — toggles, segmented control
//   pullRefresh() → .medium  — pull-to-refresh release
//   lumaResponse()→ .light   — new Luma message arrives

enum AmachHaptics {
    static func cardTap()      { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func buttonPress()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func success()      { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func error()        { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func toggle()       { UISelectionFeedbackGenerator().selectionChanged() }
    static func pullRefresh()  { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func lumaResponse() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}


// ============================================================
// MARK: - GRID & LAYOUT
// ============================================================

/// iPhone 14/15/16 Pro: 393 × 852pt logical canvas.

enum AmachLayout {
    static let screenWidth:  CGFloat = 393
    static let screenHeight: CGFloat = 852
    static let marginH:      CGFloat = AmachSpacing.screenEdge       // 16 each side
    static let contentWidth: CGFloat = 393 - (AmachSpacing.screenEdge * 2) // 361

    static let maxChatBubbleWidth: CGFloat = 0.76   // 76% of screen width
    static let maxContentWidth:    CGFloat = 560     // landscape / iPad cap
    static let cardMinHeight:      CGFloat = 100

    static var twoColumnGrid: [GridItem] {
        [GridItem(.flexible(), spacing: AmachSpacing.cardGap),
         GridItem(.flexible(), spacing: AmachSpacing.cardGap)]
    }
}


// ============================================================
// MARK: - VIEW MODIFIERS
// ============================================================

extension View {

    // ── Card Styles ──────────────────────────────────────────

    /// Level 1 card. Solid surface, subtle border.
    /// Use: MetricCard, StorageItemCard, list cards.
    func amachCard() -> some View {
        self
            .background(Color.Amach.Surface.surfaceDark)
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
            .overlay(RoundedRectangle(cornerRadius: AmachRadius.card)
                .stroke(Color.Amach.primary.opacity(AmachElevation.Level1.borderOpacity),
                        lineWidth: 1))
            .shadow(color: AmachElevation.Level1.shadowColor,
                    radius: AmachElevation.Level1.shadowRadius,
                    x: AmachElevation.Level1.shadowX,
                    y: AmachElevation.Level1.shadowY)
    }

    /// Level 2 card. More prominent shadow.
    /// Use: health score card, featured metric, sync progress.
    func amachCardElevated() -> some View {
        self
            .background(Color.Amach.Surface.elevatedDark)
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
            .overlay(RoundedRectangle(cornerRadius: AmachRadius.card)
                .stroke(Color.Amach.primary.opacity(AmachElevation.Level2.borderOpacity),
                        lineWidth: 1))
            .shadow(color: AmachElevation.Level2.shadowColor,
                    radius: AmachElevation.Level2.shadowRadius,
                    x: AmachElevation.Level2.shadowX,
                    y: AmachElevation.Level2.shadowY)
    }

    // ── AI Border ────────────────────────────────────────────

    /// Gradient border: primary → AI.base at 135°.
    /// ONLY for Luma insight cards and AI-analyzed elements.
    func amachAIBorder(radius: CGFloat = AmachRadius.card) -> some View {
        self.overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(LinearGradient(
                    colors: [Color.Amach.primary.opacity(0.6),
                             Color.Amach.AI.base.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing), lineWidth: 1)
        )
    }

    // ── Glow Effects ─────────────────────────────────────────

    /// Primary emerald glow — CTAs, health score ring, featured.
    func amachGlow() -> some View {
        self.shadow(color: Color.Amach.primary.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    /// AI indigo glow — Luma FAB, AI insight cards.
    func amachAIGlow() -> some View {
        self.shadow(color: Color.Amach.AI.base.opacity(0.30), radius: 12, x: 0, y: 4)
    }

    // ── Press Effect ──────────────────────────────────────────

    /// Scale-down on press. Apply to any tappable card or button.
    func amachPressEffect(isPressed: Bool) -> some View {
        self.scaleEffect(isPressed ? AmachAnimation.cardPressScale : 1.0)
            .animation(AmachAnimation.spring, value: isPressed)
    }
}


// ============================================================
// MARK: - COMPONENT TOKEN MAP (reference)
// ============================================================
//
// ┌─────────────────────────────────────────────────────────┐
// │ HEALTH METRIC CARD                                       │
// │ bg:      Surface.surfaceDark / surfaceLight (adaptive)   │
// │ value:   AmachType.dataValue(28), Text.primaryD/L        │
// │ unit:    AmachType.dataUnit(18), Text.secondaryD/L       │
// │ icon:    Amach.p300 (dark) / Amach.primary (light)       │
// │ border:  primary.opacity(0.12)                          │
// │ shadow:  Level1                                         │
// │ pad:     AmachSpacing.cardPadding (24)                  │
// │ radius:  AmachRadius.card (16)                          │
// │ press:   scale 0.97, spring, .light haptic              │
// ├─────────────────────────────────────────────────────────┤
// │ LUMA CHAT BUBBLE                                         │
// │ bg dark: AI.dark (#3730A3)                              │
// │ bg lite: AI.light (#EEF2FF)                             │
// │ text:    Text.onAI / AI.base                            │
// │ font:    body Regular (authority = clarity, not weight) │
// │ radius:  lg (20), zero leading-top corner               │
// │ pad:     H:16 V:12                                      │
// │ width:   max 76% screen                                 │
// │ haptic:  lumaResponse() on arrival                      │
// ├─────────────────────────────────────────────────────────┤
// │ USER CHAT BUBBLE                                         │
// │ bg dark: Amach.p400 (#10B981)                           │
// │ bg lite: Amach.primary (#006B4F)                        │
// │ text:    Text.onPrimary                                 │
// │ radius:  lg (20), zero trailing-top corner              │
// ├─────────────────────────────────────────────────────────┤
// │ PRIMARY BUTTON                                           │
// │ bg:      Amach.primary                                  │
// │ pressed: Amach.primaryDark                              │
// │ text:    Text.onPrimary, AmachType.h3 (16 Semibold)     │
// │ radius:  md (14) · pad: H:24 V:16                      │
// │ press:   scale 0.96, spring, .medium haptic             │
// │ disabled:opacity(0.5)                                   │
// ├─────────────────────────────────────────────────────────┤
// │ SECONDARY BUTTON                                         │
// │ bg:      clear · border: primary 1.5pt                  │
// │ text:    primary (light) / p300 (dark), h3              │
// │ radius:  sm (10) · pad: H:20 V:13                      │
// ├─────────────────────────────────────────────────────────┤
// │ TIER BADGE                                               │
// │ Gold:   bg goldBg, text goldText, border goldBorder      │
// │ Silver: bg silverBg, text silverText, border silverBorder│
// │ Bronze: bg bronzeBg, text bronzeText, border bronzeBorder│
// │ font:   tiny (12 Medium), UPPERCASE, tracking(0.5)      │
// │ radius: xs (6) · pad: H:8 V:4                          │
// ├─────────────────────────────────────────────────────────┤
// │ RANGE INDICATOR BAR                                      │
// │ track:  gray-200/700, height 6pt, radius pill           │
// │ fill:   Health.optimal/.borderline/.critical            │
// │ dot:    12pt, Surface.bg, Level1 shadow                 │
// ├─────────────────────────────────────────────────────────┤
// │ TOAST                                                    │
// │ bg:     Surface.elevated, Level3 shadow                 │
// │ border: Semantic.* border matching toast type           │
// │ appear: toastAppear (slide down + fade), 3s auto-dismiss│
// └─────────────────────────────────────────────────────────┘
