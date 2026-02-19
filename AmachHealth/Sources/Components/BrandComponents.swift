// BrandComponents.swift
// AmachHealth
//
// Reusable brand mark components:
//   TriskelionShape   — CGPath-based three-arm Irish spiral (Newgrange triskelion)
//   TriskelionView    — animated mark with 45s continuous rotation
//   AmachBrandMark    — composable lockup (.icon, .compact, .stacked)
//   GoldShimmerModifier — gold light-sweep animation for wordmarks

import SwiftUI

// MARK: - Triskelion Shape
//
// Three conjoined Celtic spirals — mind · body · spirit
// Each arm is a closed teardrop/leaf drawn with four cubic bezier segments,
// derived from the traditional Newgrange spiral geometry.
// The three arms are produced by rotating one arm by 0°, 120°, and 240°
// around the rect's center using CGAffineTransform.

struct TriskelionShape: Shape {
    func path(in rect: CGRect) -> Path {
        let size   = min(rect.width, rect.height)
        let cx     = rect.midX
        let cy     = rect.midY
        // SVG source arm reaches 52 units from center.
        // Scale to 85 % of the available radius so the ring has breathing room.
        let scale  = (size / 2.0) * 0.85 / 52.0

        var combined = Path()

        for i in 0..<3 {
            let angle   = CGFloat(i) * .pi * 2.0 / 3.0
            let arm     = singleArm(cx: cx, cy: cy, scale: scale)

            // Rotate around (cx, cy):
            //   1. Translate so center moves to origin
            //   2. Rotate
            //   3. Translate back
            let transform = CGAffineTransform(translationX: -cx, y: -cy)
                .rotated(by: angle)
                .translatedBy(x: cx, y: cy)

            combined.addPath(arm.applying(transform))
        }

        return combined
    }

    /// One teardrop arm pointing directly upward (-y in screen coords).
    /// Derived from SVG:
    /// M0,0 C0,-15 8,-28 12,-38  C16,-48 10,-55 0,-52  C-10,-49 -12,-38 -6,-28  C-2,-20 0,-10 0,0
    private func singleArm(cx: CGFloat, cy: CGFloat, scale s: CGFloat) -> Path {
        var p = Path()

        p.move(to: .init(x: cx,        y: cy))

        // Outer curve: center → right-up → tip area
        p.addCurve(
            to:       .init(x: cx + 12*s, y: cy - 38*s),
            control1: .init(x: cx,        y: cy - 15*s),
            control2: .init(x: cx +  8*s, y: cy - 28*s)
        )
        // Over the top: right-tip → top
        p.addCurve(
            to:       .init(x: cx,        y: cy - 52*s),
            control1: .init(x: cx + 16*s, y: cy - 48*s),
            control2: .init(x: cx + 10*s, y: cy - 55*s)
        )
        // Inner curve: top → left-side
        p.addCurve(
            to:       .init(x: cx -  6*s, y: cy - 28*s),
            control1: .init(x: cx - 10*s, y: cy - 49*s),
            control2: .init(x: cx - 12*s, y: cy - 38*s)
        )
        // Return to center
        p.addCurve(
            to:       .init(x: cx,        y: cy),
            control1: .init(x: cx -  2*s, y: cy - 20*s),
            control2: .init(x: cx,        y: cy - 10*s)
        )

        p.closeSubpath()
        return p
    }
}

// MARK: - Animated Triskelion View

struct TriskelionView: View {
    var size: CGFloat      = 80
    var showRing: Bool     = true

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // Subtle binding ring (optional)
            if showRing {
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.amachPrimaryBright.opacity(0.4),
                                Color.amachPrimary.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            }

            // Triskelion fill
            TriskelionShape()
                .fill(
                    LinearGradient(
                        colors: [Color.amachPrimaryBright, Color.amachPrimary],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .padding(showRing ? size * 0.14 : 0)
                // Soft emerald glow
                .shadow(
                    color: Color.amachPrimaryBright.opacity(0.28),
                    radius: size * 0.12,
                    x: 0, y: 0
                )
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(rotation))
        .onAppear {
            // 45 s per revolution — meditative, barely perceptible drift
            withAnimation(.linear(duration: 45).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Gold Shimmer Modifier
//
// Sweeps a narrow gold gradient stripe across any view (typically text).
// The gradient is clipped to the shape of the view it modifies via .mask().
// Usage:  Text("AMACH").goldShimmer()

struct GoldShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    var duration: Double  = 4.5
    var delay: Double     = 0.6

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    let w         = geo.size.width
                    let stripW    = w * 0.42           // width of the shimmer stripe
                    let startX    = -stripW            // fully hidden left
                    let travel    = w + stripW         // total distance to cross

                    LinearGradient(
                        colors: [
                            .clear,
                            Color(hex: "D97706").opacity(0.75),
                            Color(hex: "FBBF24"),
                            Color(hex: "D97706").opacity(0.65),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint:   .trailing
                    )
                    .frame(width: stripW)
                    .offset(x: startX + phase * travel)
                    .onAppear {
                        withAnimation(
                            .easeInOut(duration: duration)
                            .delay(delay)
                            .repeatForever(autoreverses: false)
                        ) {
                            phase = 1
                        }
                    }
                }
                // Clip shimmer to the exact shape of the wrapped view
                .mask(content)
                .clipped()
            )
    }
}

extension View {
    /// Applies an animated gold light-sweep over this view.
    func goldShimmer(duration: Double = 4.5, delay: Double = 0.6) -> some View {
        modifier(GoldShimmerModifier(duration: duration, delay: delay))
    }
}

// MARK: - Amach Brand Mark
//
// Composable lockup combining the triskelion icon and the wordmark.
//
//   .icon     — triskelion only           (32 pt, nav bars / tab bar)
//   .compact  — icon + inline wordmark    (header rows in views)
//   .stacked  — icon above wordmark       (splash, onboarding, settings)

enum BrandMarkLayout {
    case icon
    case compact
    case stacked
}

struct AmachBrandMark: View {
    var layout:   BrandMarkLayout = .stacked
    var iconSize: CGFloat?        = nil

    private var resolvedIconSize: CGFloat {
        if let s = iconSize { return s }
        switch layout {
        case .icon:    return 48
        case .compact: return 28
        case .stacked: return 68
        }
    }

    var body: some View {
        switch layout {

        // ── Icon only ──────────────────────────────────────────────────────
        case .icon:
            TriskelionView(size: resolvedIconSize)

        // ── Compact: icon + wordmark side by side ──────────────────────────
        case .compact:
            HStack(spacing: 9) {
                TriskelionView(size: resolvedIconSize, showRing: false)

                VStack(alignment: .leading, spacing: 1) {
                    Text("AMACH")
                        .font(.system(size: 13, weight: .bold))
                        .kerning(3)
                        .foregroundStyle(Color.amachTextPrimary)
                        .goldShimmer(duration: 4.5, delay: 1.2)

                    Text("HEALTH")
                        .font(.system(size: 7.5, weight: .medium))
                        .kerning(3.5)
                        .foregroundStyle(Color.amachPrimaryBright.opacity(0.7))
                }
            }

        // ── Stacked: icon above wordmark ───────────────────────────────────
        case .stacked:
            VStack(spacing: 14) {
                TriskelionView(size: resolvedIconSize)

                VStack(spacing: 5) {
                    Text("AMACH")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                        .kerning(6)
                        .foregroundStyle(Color.amachTextPrimary)
                        .goldShimmer(duration: 4.5, delay: 0.8)

                    Text("HEALTH")
                        .font(.system(size: 9, weight: .light))
                        .kerning(7)
                        .foregroundStyle(Color.amachPrimaryBright.opacity(0.65))

                    Text("outward · into life")
                        .font(.system(size: 11, weight: .light))
                        .italic()
                        .foregroundStyle(Color.amachTextSecondary.opacity(0.6))
                        .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Brand Mark — all layouts") {
    ZStack {
        Color.amachBg.ignoresSafeArea()

        VStack(spacing: 48) {
            AmachBrandMark(layout: .stacked)

            Divider().overlay(Color.amachPrimary.opacity(0.2))

            AmachBrandMark(layout: .compact)

            Divider().overlay(Color.amachPrimary.opacity(0.2))

            AmachBrandMark(layout: .icon)
        }
        .padding(40)
    }
    .preferredColorScheme(.dark)
}
