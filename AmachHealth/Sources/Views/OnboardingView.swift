// OnboardingView.swift
// AmachHealth
//
// Multi-step onboarding: Welcome → Own → Meet Luma → Health Permission → Ready
//
// Design goals:
//   • Earn the HealthKit "Allow" tap — frame permission as empowering, not extractive.
//   • Introduce Luma before asking for data — she's why the data matters.
//   • First sync feels exciting, not like a loading screen.
//   • Each step has a single clear CTA. No overwhelm.

import SwiftUI

// ============================================================
// MARK: - ONBOARDING COORDINATOR
// ============================================================

struct OnboardingView: View {
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @EnvironmentObject private var healthKit: HealthKitService
    @EnvironmentObject private var wallet: WalletService

    @State private var currentStep = 0
    @State private var isRequestingPermission = false
    @State private var permissionDenied = false

    // Steps: 0=Welcome, 1=Own, 2=MeetLuma, 3=HealthPermission, 4=Ready
    private let totalSteps = 5

    var body: some View {
        ZStack {
            Color.amachBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress indicator (hidden on step 0)
                if currentStep > 0 {
                    stepIndicator
                        .padding(.top, AmachSpacing.md)
                        .padding(.horizontal, AmachSpacing.xl)
                        .transition(.opacity)
                }

                // Step content
                TabView(selection: $currentStep) {
                    WelcomeStep(onContinue: { advance() })
                        .tag(0)

                    OwnYourDataStep(onContinue: { advance() })
                        .tag(1)

                    MeetLumaStep(onContinue: { advance() })
                        .tag(2)

                    HealthPermissionStep(
                        isRequesting: $isRequestingPermission,
                        permissionDenied: $permissionDenied,
                        onAllow: { await requestHealthKit() },
                        onSkip: { advance() }
                    )
                    .tag(3)

                    ReadyStep(
                        onGetStarted: { finish() }
                    )
                    .tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(AmachAnimation.ifMotion(.easeInOut(duration: 0.35)), value: currentStep)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Progress Dots

    private var stepIndicator: some View {
        HStack(spacing: AmachSpacing.sm) {
            ForEach(1..<totalSteps, id: \.self) { i in
                Capsule()
                    .fill(currentStep >= i ? Color.amachPrimaryBright : Color.amachPrimary.opacity(0.2))
                    .frame(width: currentStep == i ? 24 : 8, height: 4)
                    .animation(AmachAnimation.spring, value: currentStep)
            }
        }
    }

    // MARK: Navigation

    private func advance() {
        withAnimation(AmachAnimation.ifMotion(.easeInOut(duration: 0.3))) {
            currentStep = min(currentStep + 1, totalSteps - 1)
        }
    }

    private func requestHealthKit() async {
        isRequestingPermission = true
        do {
            try await healthKit.requestAuthorization()
            advance()
        } catch {
            permissionDenied = true
        }
        isRequestingPermission = false
    }

    private func finish() {
        withAnimation(AmachAnimation.spring) {
            onboardingComplete = true
        }
    }
}


// ============================================================
// MARK: - STEP 0: WELCOME
// ============================================================

private struct WelcomeStep: View {
    let onContinue: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Brand mark
            AmachBrandMark(layout: .stacked, iconSize: 80)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)
                .animation(
                    AmachAnimation.ifMotion(.easeOut(duration: 0.6)),
                    value: appeared
                )

            Spacer().frame(height: AmachSpacing.xxl)

            // Tagline
            VStack(spacing: AmachSpacing.sm) {
                Text("Own your data.")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.amachTextPrimary)
                Text("Keep the value.")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.amachPrimaryBright)
                Text("Read the signals.")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color.amachTextPrimary)
            }
            .multilineTextAlignment(.center)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(
                AmachAnimation.ifMotion(.easeOut(duration: 0.6).delay(0.15)),
                value: appeared
            )

            Spacer().frame(height: AmachSpacing.md)

            Text("Health data that works for you — not the system.")
                .font(AmachType.body)
                .foregroundStyle(Color.amachTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AmachSpacing.xl)
                .opacity(appeared ? 1 : 0)
                .animation(
                    AmachAnimation.ifMotion(.easeOut(duration: 0.6).delay(0.25)),
                    value: appeared
                )

            Spacer()

            // CTA
            Button("Get Started") { onContinue() }
                .amachPrimaryButtonStyle()
                .padding(.horizontal, AmachSpacing.xl)
                .opacity(appeared ? 1 : 0)
                .animation(
                    AmachAnimation.ifMotion(.easeOut(duration: 0.5).delay(0.4)),
                    value: appeared
                )

            Spacer().frame(height: AmachSpacing.xl)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appeared = true
            }
        }
    }
}


// ============================================================
// MARK: - STEP 1: OWN YOUR DATA
// ============================================================

private struct OwnYourDataStep: View {
    let onContinue: () -> Void
    @State private var appeared = false

    private let pillars: [(icon: String, color: Color, title: String, body: String)] = [
        (
            "lock.shield.fill",
            Color.amachPrimaryBright,
            "Yours to own",
            "Encrypted and stored in your personal vault. We never sell or share your data."
        ),
        (
            "sparkles",
            Color.Amach.AI.p400,
            "Yours to understand",
            "AI-powered insights from Luma — patterns, not prescriptions."
        ),
        (
            "chart.line.uptrend.xyaxis",
            Color.amachAccent,
            "Yours to benefit from",
            "Value created from your health data flows back to you, verified on-chain."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: AmachSpacing.xl) {
                VStack(spacing: AmachSpacing.sm) {
                    Text("Your health data\nshould work for you.")
                        .font(AmachType.h1)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.amachTextPrimary)

                    Text("Not for advertisers. Not for insurers.\nNot for anyone without your consent.")
                        .font(AmachType.body)
                        .foregroundStyle(Color.amachTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }

                VStack(spacing: AmachSpacing.sm) {
                    ForEach(pillars.indices, id: \.self) { i in
                        let p = pillars[i]
                        PillarCard(
                            icon: p.icon,
                            iconColor: p.color,
                            title: p.title,
                            body: p.body
                        )
                        .opacity(appeared ? 1 : 0)
                        .offset(x: appeared ? 0 : 30)
                        .animation(
                            AmachAnimation.ifMotion(.easeOut(duration: 0.5).delay(Double(i) * 0.1 + 0.1)),
                            value: appeared
                        )
                    }
                }
                .padding(.horizontal, AmachSpacing.md)
            }

            Spacer()

            Button("Next") { onContinue() }
                .amachPrimaryButtonStyle()
                .padding(.horizontal, AmachSpacing.xl)

            Spacer().frame(height: AmachSpacing.xl)
        }
        .onAppear { appeared = true }
    }
}

private struct PillarCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let body: String

    var body: some View {
        HStack(alignment: .center, spacing: AmachSpacing.md) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AmachType.h3)
                    .foregroundStyle(Color.amachTextPrimary)
                Text(body)
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(AmachSpacing.md)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AmachRadius.card)
                .stroke(iconColor.opacity(0.12), lineWidth: 1)
        )
    }
}


// ============================================================
// MARK: - STEP 2: MEET LUMA
// ============================================================

private struct MeetLumaStep: View {
    let onContinue: () -> Void
    @State private var appeared = false
    @State private var typedText = ""

    private let fullText = "Hi. I'm Luma — your AI health companion.\n\nI read your data and find patterns, not prescriptions. I'll tell you what I see. I'll name what I don't know. And I'll always distinguish a signal from noise.\n\nYour body is a complex system. Let's understand it together."

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: AmachSpacing.xl) {
                // Luma avatar
                ZStack {
                    Circle()
                        .fill(Color.Amach.AI.base.opacity(0.08))
                        .frame(width: 120, height: 120)
                    Circle()
                        .fill(Color.Amach.AI.base.opacity(0.05))
                        .frame(width: 150, height: 150)
                    Image(systemName: "sparkles")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(Color.Amach.AI.p400)
                        .shadow(color: Color.Amach.AI.base.opacity(0.45), radius: 20)
                }
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)
                .animation(AmachAnimation.ifMotion(AmachAnimation.spring), value: appeared)

                // Luma's intro message — simulated chat bubble
                VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                    HStack(spacing: AmachSpacing.sm) {
                        Circle()
                            .fill(Color.Amach.AI.base.opacity(0.18))
                            .frame(width: 28, height: 28)
                            .overlay(
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.Amach.AI.p400)
                            )
                        Text("Luma")
                            .font(AmachType.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.Amach.AI.p400)
                    }

                    Text(typedText)
                        .font(AmachType.body)
                        .foregroundStyle(Color.amachTextPrimary)
                        .lineSpacing(5)
                        .padding(.horizontal, AmachSpacing.md)
                        .padding(.vertical, AmachSpacing.sm + 4)
                        .background(Color.Amach.AI.dark.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: AmachRadius.lg)
                                .stroke(Color.Amach.AI.base.opacity(0.22), lineWidth: 1)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AmachSpacing.md)
                .opacity(appeared ? 1 : 0)
                .animation(
                    AmachAnimation.ifMotion(.easeOut(duration: 0.4).delay(0.3)),
                    value: appeared
                )
            }

            Spacer()

            Button("Meet Her") { onContinue() }
                .amachPrimaryButtonStyle()
                .padding(.horizontal, AmachSpacing.xl)

            Spacer().frame(height: AmachSpacing.xl)
        }
        .onAppear {
            appeared = true
            // Type out the text
            if !UIAccessibility.isReduceMotionEnabled {
                typedText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    typeText()
                }
            } else {
                typedText = fullText
            }
        }
    }

    private func typeText() {
        let chars = Array(fullText)
        for (i, char) in chars.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.012) {
                typedText += String(char)
            }
        }
    }
}


// ============================================================
// MARK: - STEP 3: APPLE HEALTH PERMISSION
// ============================================================
// Critical: The copy and visual must earn the "Allow" tap.
// Frame it as: "We read so Luma can understand. You control."
// Show exactly what categories will be accessed.
// Never mention "upload" or "share" — say "read" and "analyze."

private struct HealthPermissionStep: View {
    @Binding var isRequesting: Bool
    @Binding var permissionDenied: Bool
    let onAllow: () async -> Void
    let onSkip: () -> Void

    private let categories: [(icon: String, name: String, why: String)] = [
        ("figure.walk",          "Activity",    "Steps, workouts, energy burned"),
        ("heart.fill",           "Heart",       "Heart rate, HRV, resting HR"),
        ("moon.fill",            "Sleep",       "Sleep stages and efficiency"),
        ("waveform.path.ecg",    "Vitals",      "Blood oxygen, respiratory rate"),
        ("drop.fill",            "Glucose",     "Blood glucose (CGM if available)"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: AmachSpacing.xl) {
                    Spacer().frame(height: AmachSpacing.lg)

                    // Header
                    VStack(spacing: AmachSpacing.sm) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "F87171").opacity(0.12))
                                .frame(width: 72, height: 72)
                            Image(systemName: "heart.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Color(hex: "F87171"))
                        }

                        Text("Connect Apple Health")
                            .font(AmachType.h1)
                            .foregroundStyle(Color.amachTextPrimary)
                            .multilineTextAlignment(.center)

                        Text("Luma reads your health data so she can find patterns. Your data never leaves your device unencrypted — it's stored in your personal vault.")
                            .font(AmachType.body)
                            .foregroundStyle(Color.amachTextSecondary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .padding(.horizontal, AmachSpacing.md)
                    }

                    // Categories list
                    VStack(spacing: 0) {
                        Text("LUMA WILL READ")
                            .font(AmachType.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.amachTextSecondary)
                            .tracking(1.2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, AmachSpacing.md)
                            .padding(.bottom, AmachSpacing.sm)

                        VStack(spacing: AmachSpacing.xs) {
                            ForEach(categories.indices, id: \.self) { i in
                                let cat = categories[i]
                                HStack(spacing: AmachSpacing.md) {
                                    Image(systemName: cat.icon)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.amachPrimaryBright)
                                        .frame(width: 20)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(cat.name)
                                            .font(AmachType.caption)
                                            .fontWeight(.medium)
                                            .foregroundStyle(Color.amachTextPrimary)
                                        Text(cat.why)
                                            .font(AmachType.tiny)
                                            .foregroundStyle(Color.amachTextSecondary)
                                    }

                                    Spacer()

                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.amachPrimaryBright)
                                }
                                .padding(.horizontal, AmachSpacing.md)
                                .padding(.vertical, AmachSpacing.sm + 2)

                                if i < categories.count - 1 {
                                    Divider()
                                        .overlay(Color.amachPrimary.opacity(0.08))
                                        .padding(.horizontal, AmachSpacing.md)
                                }
                            }
                        }
                        .background(Color.amachSurface)
                        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
                        .overlay(
                            RoundedRectangle(cornerRadius: AmachRadius.card)
                                .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 1)
                        )
                        .padding(.horizontal, AmachSpacing.md)
                    }

                    // Privacy note
                    HStack(spacing: AmachSpacing.sm) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.amachPrimaryBright)
                        Text("We never write to Apple Health. Read-only access. You can revoke anytime in iPhone Settings.")
                            .font(AmachType.tiny)
                            .foregroundStyle(Color.amachTextSecondary)
                            .lineSpacing(3)
                    }
                    .padding(AmachSpacing.sm + 4)
                    .background(Color.amachPrimary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
                    .padding(.horizontal, AmachSpacing.md)

                    // Permission denied state
                    if permissionDenied {
                        HStack(spacing: AmachSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.amachWarning)
                                .font(AmachType.caption)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Permission needed")
                                    .font(AmachType.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.amachTextPrimary)
                                Text("Go to iPhone Settings → Privacy → Health → Amach to enable access.")
                                    .font(AmachType.tiny)
                                    .foregroundStyle(Color.amachTextSecondary)
                                    .lineSpacing(2)
                            }
                        }
                        .padding(AmachSpacing.sm + 4)
                        .background(Color.amachWarning.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AmachRadius.sm)
                                .stroke(Color.amachWarning.opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal, AmachSpacing.md)
                    }

                    Spacer().frame(height: AmachSpacing.lg)
                }
            }

            // CTAs
            VStack(spacing: AmachSpacing.sm) {
                Button {
                    Task { await onAllow() }
                } label: {
                    HStack(spacing: AmachSpacing.sm) {
                        if isRequesting {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 15))
                        }
                        Text(isRequesting ? "Requesting…" : "Connect Apple Health")
                    }
                }
                .amachPrimaryButtonStyle(isLoading: isRequesting)
                .disabled(isRequesting)
                .padding(.horizontal, AmachSpacing.xl)

                Button("Skip for now") { onSkip() }
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
                    .padding(.vertical, AmachSpacing.sm)
                    .accessibilityHint("You can connect Apple Health later in Settings.")
            }

            Spacer().frame(height: AmachSpacing.xl)
        }
    }
}


// ============================================================
// MARK: - STEP 4: READY
// ============================================================

private struct ReadyStep: View {
    let onGetStarted: () -> Void
    @State private var appeared = false

    private let features: [(icon: String, color: Color, text: String)] = [
        ("chart.xyaxis.line",  Color.amachPrimaryBright, "Your health overview, updated in real time"),
        ("sparkles",           Color.Amach.AI.p400,      "Luma ready to answer your questions"),
        ("arrow.triangle.2.circlepath", Color.amachAccent, "Sync data to your encrypted vault anytime"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: AmachSpacing.xxl) {
                // Success mark
                ZStack {
                    Circle()
                        .fill(Color.amachPrimary.opacity(0.08))
                        .frame(width: 100, height: 100)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.amachPrimaryBright)
                        .shadow(color: Color.amachPrimary.opacity(0.4), radius: 16)
                }
                .scaleEffect(appeared ? 1 : 0.5)
                .opacity(appeared ? 1 : 0)
                .animation(AmachAnimation.ifMotion(AmachAnimation.spring.delay(0.1)), value: appeared)

                VStack(spacing: AmachSpacing.sm) {
                    Text("You're set.")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Color.amachTextPrimary)

                    Text("Amach is ready. Luma is ready.\nLet's see what your data says.")
                        .font(AmachType.body)
                        .foregroundStyle(Color.amachTextSecondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .opacity(appeared ? 1 : 0)
                .animation(AmachAnimation.ifMotion(.easeOut(duration: 0.5).delay(0.2)), value: appeared)

                // Feature list
                VStack(alignment: .leading, spacing: AmachSpacing.md) {
                    ForEach(features.indices, id: \.self) { i in
                        let f = features[i]
                        HStack(spacing: AmachSpacing.md) {
                            Image(systemName: f.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(f.color)
                                .frame(width: 24)
                            Text(f.text)
                                .font(AmachType.caption)
                                .foregroundStyle(Color.amachTextSecondary)
                                .lineSpacing(2)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(x: appeared ? 0 : 20)
                        .animation(
                            AmachAnimation.ifMotion(.easeOut(duration: 0.4).delay(0.3 + Double(i) * 0.08)),
                            value: appeared
                        )
                    }
                }
                .padding(.horizontal, AmachSpacing.xl)
            }

            Spacer()

            Button("Open Amach") { onGetStarted() }
                .amachPrimaryButtonStyle()
                .padding(.horizontal, AmachSpacing.xl)
                .opacity(appeared ? 1 : 0)
                .animation(AmachAnimation.ifMotion(.easeOut(duration: 0.5).delay(0.5)), value: appeared)

            Spacer().frame(height: AmachSpacing.xl)
        }
        .onAppear { appeared = true }
    }
}


// ============================================================
// MARK: - PREVIEW
// ============================================================

#Preview("Onboarding — Welcome") {
    OnboardingView()
        .environmentObject(HealthKitService.shared)
        .environmentObject(WalletService.shared)
        .preferredColorScheme(.dark)
}
