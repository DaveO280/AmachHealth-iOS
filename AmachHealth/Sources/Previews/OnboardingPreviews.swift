// OnboardingPreviews.swift
// AmachHealth

import SwiftUI

#Preview("Onboarding — Step 0: Welcome") {
    OnboardingView()
        .environmentObject(HealthKitService.shared)
        .environmentObject(WalletService.shared)
        .preferredColorScheme(.dark)
}

// Steps 1–4 are navigated to via tap — preview the coordinator
// at step 0 and swipe/tap through in Canvas to inspect each step.
// For static Figma frames, use the individual step views below.

#Preview("Onboarding — Step 1: Own Your Data") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        OwnYourDataStep(onContinue: {})
            .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — Step 2: Meet Luma") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        MeetLumaStep(onContinue: {})
            .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — Step 3: Health Permission") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        HealthPermissionStep(
            isRequesting: .constant(false),
            permissionDenied: .constant(false),
            onAllow: {},
            onSkip: {}
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — Step 3: Permission Denied 🔴") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        HealthPermissionStep(
            isRequesting: .constant(false),
            permissionDenied: .constant(true),
            onAllow: {},
            onSkip: {}
        )
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Onboarding — Step 4: Ready 🟢") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        ReadyStep(onGetStarted: {})
            .padding()
    }
    .preferredColorScheme(.dark)
}
