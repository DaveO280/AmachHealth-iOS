// FeedbackComponents.swift
// AmachHealth
//
// User feedback and state-communication components.
// These communicate system state, loading, errors, and
// results to the user in a way that matches the Amach tone:
// clear, calm, never alarmist.
//
// Components:
//   AmachToast              — ephemeral top notification (3s auto-dismiss)
//   AmachProgressBar        — horizontal named progress with animation
//   AmachEmptyState         — zero-data full-view placeholder
//   AmachBanner             — inline dismissible alert (success/warning/error/info)
//   AmachLoadingView        — centered spinner + label
//   AmachConfirmationSheet  — destructive action confirmation half-sheet

import SwiftUI


// ============================================================
// MARK: - TOAST SYSTEM
// ============================================================
//
// Slide-in notification appearing below the Dynamic Island.
// Auto-dismisses after 3 seconds. Swipe up to dismiss early.
//
// Setup (once, on root/tab view):
//   .amachToast(toast: $currentToast)
//
// Usage from any view or service:
//   currentToast = AmachToast.success("Sync complete")
//   currentToast = AmachToast.error("Upload failed — tap to retry", action: retry, actionLabel: "Retry")

struct AmachToast: Equatable {

    enum Style { case success, warning, error, info }

    let id: UUID
    let message: String
    let style: Style
    var actionLabel: String?  = nil
    var action: (() -> Void)? = nil

    // Equatable based on id only — closures are not equatable
    static func == (lhs: AmachToast, rhs: AmachToast) -> Bool { lhs.id == rhs.id }

    // MARK: Factories

    static func success(_ message: String) -> AmachToast {
        AmachToast(id: UUID(), message: message, style: .success)
    }
    static func warning(_ message: String) -> AmachToast {
        AmachToast(id: UUID(), message: message, style: .warning)
    }
    static func error(_ message: String, action: (() -> Void)? = nil, actionLabel: String? = nil) -> AmachToast {
        AmachToast(id: UUID(), message: message, style: .error, actionLabel: actionLabel, action: action)
    }
    static func info(_ message: String) -> AmachToast {
        AmachToast(id: UUID(), message: message, style: .info)
    }

    // MARK: Appearance tokens

    var icon: String {
        switch style {
        case .success: return AmachIcon.successIcon
        case .warning: return AmachIcon.warning
        case .error:   return AmachIcon.errorIcon
        case .info:    return AmachIcon.info
        }
    }

    var accentColor: Color {
        switch style {
        case .success: return Color.Amach.Semantic.success
        case .warning: return Color.Amach.Semantic.warning
        case .error:   return Color.Amach.Semantic.error
        case .info:    return Color.Amach.Semantic.info
        }
    }

    var borderColor: Color {
        switch style {
        case .success: return Color.Amach.Semantic.successBorder
        case .warning: return Color.Amach.Semantic.warningBorder
        case .error:   return Color.Amach.Semantic.errorBorder
        case .info:    return Color.Amach.Semantic.infoBorder
        }
    }
}


// Toast view body (internal — rendered by the modifier)
private struct AmachToastView: View {
    let toast: AmachToast
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: AmachSpacing.sm) {
            Image(systemName: toast.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(toast.accentColor)

            Text(toast.message)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let label = toast.actionLabel, let action = toast.action {
                Button(label) { action(); onDismiss() }
                    .amachTertiaryButtonStyle()
                    .padding(.trailing, 2)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.amachTextTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AmachSpacing.md)
        .padding(.vertical, AmachSpacing.sm + 2)
        .background(
            Color.amachElevated
                .shadow(
                    .drop(
                        color: AmachElevation.Level3.shadowColor,
                        radius: 20,
                        x: 0,
                        y: 8
                    )
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AmachRadius.md)
                .stroke(toast.borderColor.opacity(0.45), lineWidth: 1)
        )
        .accessibilityLabel(toast.message)
        .accessibilityAddTraits(.isStaticText)
    }
}


// Toast host modifier — attach to any root or tab-level view
struct AmachToastModifier: ViewModifier {
    @Binding var toast: AmachToast?
    @State private var isVisible = false
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let current = toast, isVisible {
                    AmachToastView(toast: current, onDismiss: dismiss)
                        .padding(.horizontal, AmachSpacing.md)
                        .padding(.top, AmachSpacing.xs)
                        .transition(
                            .move(edge: .top).combined(with: .opacity)
                        )
                        .gesture(
                            DragGesture(minimumDistance: 10)
                                .onEnded { v in if v.translation.height < -10 { dismiss() } }
                        )
                        .zIndex(999)
                }
            }
            .onChange(of: toast) { _, newToast in
                guard newToast != nil else { return }
                show()
            }
            .animation(
                AmachAnimation.ifMotion(AmachAnimation.toastAppear),
                value: isVisible
            )
    }

    private func show() {
        dismissTask?.cancel()
        isVisible = true
        dismissTask = Task {
            try? await Task.sleep(
                nanoseconds: UInt64(AmachAnimation.durationToastVisible * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { dismiss() }
        }
    }

    private func dismiss() {
        withAnimation(AmachAnimation.ifMotion(AmachAnimation.toastDismiss)) {
            isVisible = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            toast = nil
        }
    }
}

extension View {
    /// Attach once to a root view. Any child can then write to the bound `AmachToast?`.
    func amachToast(toast: Binding<AmachToast?>) -> some View {
        modifier(AmachToastModifier(toast: toast))
    }
}


// ============================================================
// MARK: - PROGRESS BAR
// ============================================================
//
// Horizontal fill bar with optional label and percentage.
// Used for sync progress, data completeness, onboarding steps.
//
// value: 0.0–1.0
// Animates fill on first appear and on subsequent value changes.
//
// Usage:
//   AmachProgressBar(value: syncProgress, label: "Uploading health data")
//   AmachProgressBar(value: completeness, color: .amachAccent, showPercentage: false)

struct AmachProgressBar: View {
    let value: Double             // 0.0–1.0
    var label: String?    = nil
    var showPercentage: Bool = true
    var color: Color      = Color.amachPrimary

    @State private var displayValue: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.xs) {
            // Header row
            if label != nil || showPercentage {
                HStack {
                    if let label {
                        Text(label)
                            .font(AmachType.caption)
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                    Spacer()
                    if showPercentage {
                        Text("\(Int(displayValue * 100))%")
                            .font(AmachType.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.amachTextPrimary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
            }

            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: AmachRadius.pill)
                        .fill(color.opacity(0.15))
                        .frame(height: 6)
                    // Fill
                    RoundedRectangle(cornerRadius: AmachRadius.pill)
                        .fill(color)
                        .frame(
                            width: geo.size.width * min(max(displayValue, 0), 1),
                            height: 6
                        )
                        .shadow(color: color.opacity(0.35), radius: 4)
                }
            }
            .frame(height: 6)
        }
        .onAppear {
            withAnimation(AmachAnimation.ifMotion(.easeOut(duration: 0.6))) {
                displayValue = value
            }
        }
        .onChange(of: value) { _, newVal in
            withAnimation(AmachAnimation.ifMotion(AmachAnimation.normal)) {
                displayValue = newVal
            }
        }
        .accessibilityLabel(label ?? "Progress")
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}


// ============================================================
// MARK: - EMPTY STATE
// ============================================================
//
// Full-area placeholder for zero-data screens.
// Composed of: illustration halo + icon, headline, body, optional CTAs.
//
// tintColor defaults to amachPrimary. Use Color.Amach.AI.p400
// for Luma-context empty states.
//
// Usage:
//   AmachEmptyState(
//       icon: "waveform.path.ecg",
//       title: "No trends yet",
//       body: "Sync your health data and Luma will start finding patterns.",
//       ctaLabel: "Sync Now",
//       ctaAction: { … }
//   )

struct AmachEmptyState: View {
    let icon: String
    let title: String
    let body: String
    var tintColor: Color       = Color.amachPrimary
    var ctaLabel: String?      = nil
    var ctaAction: (() -> Void)? = nil
    var secondaryLabel: String?      = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: AmachSpacing.xl) {
            Spacer()

            // Illustration halo
            ZStack {
                Circle()
                    .fill(tintColor.opacity(0.04))
                    .frame(width: 160, height: 160)
                Circle()
                    .fill(tintColor.opacity(0.07))
                    .frame(width: 128, height: 128)
                Image(systemName: icon)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(tintColor.opacity(0.60))
                    .shadow(color: tintColor.opacity(0.22), radius: 20)
            }

            // Text content
            VStack(spacing: AmachSpacing.sm) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Color.amachTextPrimary)
                    .multilineTextAlignment(.center)
                    .tracking(-0.2)

                Text(body)
                    .font(AmachType.body)
                    .foregroundStyle(Color.amachTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, AmachSpacing.xl)
            }

            // CTA buttons
            if ctaLabel != nil || secondaryLabel != nil {
                VStack(spacing: AmachSpacing.sm) {
                    if let ctaLabel, let ctaAction {
                        Button(ctaLabel, action: ctaAction)
                            .amachPrimaryButtonStyle()
                            .padding(.horizontal, AmachSpacing.xl)
                    }
                    if let secondaryLabel, let secondaryAction {
                        Button(secondaryLabel, action: secondaryAction)
                            .amachTertiaryButtonStyle()
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}


// ============================================================
// MARK: - INLINE BANNER
// ============================================================
//
// Persistent in-content alert. Not floating — sits inside the
// scroll view like a card. Dismissible via X button.
//
// Use for non-critical but meaningful notices (e.g., sync warning,
// partial data alert). For critical one-time errors, prefer Toast.
//
// Usage:
//   AmachBanner(
//       .warning,
//       message: "Your last sync had errors. Some data may be missing.",
//       actionLabel: "Retry",
//       action: retrySync,
//       isDismissed: $bannerDismissed
//   )

struct AmachBanner: View {

    enum Style { case success, warning, error, info }

    let style: Style
    let message: String
    var actionLabel: String?  = nil
    var action: (() -> Void)? = nil
    @Binding var isDismissed: Bool

    @Environment(\.colorScheme) private var scheme

    private var tokens: (icon: Color, bg: Color, border: Color, text: Color) {
        let dark = scheme == .dark
        switch style {
        case .success:
            return (
                Color.Amach.Semantic.success,
                dark ? Color.Amach.Semantic.successBgD : Color.Amach.Semantic.successBgL,
                Color.Amach.Semantic.successBorder,
                dark ? Color.Amach.Semantic.successTextD : Color.Amach.Semantic.successTextL
            )
        case .warning:
            return (
                Color.Amach.Semantic.warning,
                dark ? Color.Amach.Semantic.warningBgD : Color.Amach.Semantic.warningBgL,
                Color.Amach.Semantic.warningBorder,
                dark ? Color.Amach.Semantic.warningTextD : Color.Amach.Semantic.warningTextL
            )
        case .error:
            return (
                Color.Amach.Semantic.error,
                dark ? Color.Amach.Semantic.errorBgD : Color.Amach.Semantic.errorBgL,
                Color.Amach.Semantic.errorBorder,
                dark ? Color.Amach.Semantic.errorTextD : Color.Amach.Semantic.errorTextL
            )
        case .info:
            return (
                Color.Amach.Semantic.info,
                dark ? Color.Amach.Semantic.infoBgD : Color.Amach.Semantic.infoBgL,
                Color.Amach.Semantic.infoBorder,
                dark ? Color.Amach.Semantic.infoTextD : Color.Amach.Semantic.infoTextL
            )
        }
    }

    private var iconName: String {
        switch style {
        case .success: return AmachIcon.successIcon
        case .warning: return AmachIcon.warning
        case .error:   return AmachIcon.errorIcon
        case .info:    return AmachIcon.info
        }
    }

    var body: some View {
        if !isDismissed {
            HStack(alignment: .top, spacing: AmachSpacing.sm) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tokens.icon)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(AmachType.caption)
                        .foregroundStyle(tokens.text)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    if let label = actionLabel, let action {
                        Button(label, action: action)
                            .font(AmachType.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(tokens.icon)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    withAnimation(AmachAnimation.ifMotion(AmachAnimation.fast)) {
                        isDismissed = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.text.opacity(0.55))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(AmachSpacing.md)
            .background(tokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AmachRadius.md)
                    .stroke(tokens.border.opacity(0.45), lineWidth: 1)
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}


// ============================================================
// MARK: - LOADING VIEW
// ============================================================
//
// Full-area centered activity indicator with optional message.
// Use for screens that must load before rendering (cold start,
// first data fetch). For partial loading, use AmachProgressBar.
//
// Usage:
//   AmachLoadingView()
//   AmachLoadingView(message: "Fetching your health data…")
//   AmachLoadingView(message: "Connecting to Luma…", tint: Color.Amach.AI.base)

struct AmachLoadingView: View {
    var message: String = "Loading…"
    var tint: Color     = Color.amachPrimary

    var body: some View {
        VStack(spacing: AmachSpacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(tint)

            Text(message)
                .font(AmachType.caption)
                .foregroundStyle(Color.amachTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(message)
        .accessibilityAddTraits(.updatesFrequently)
    }
}


// ============================================================
// MARK: - CONFIRMATION SHEET
// ============================================================
//
// Half-sheet that requires explicit user confirmation before a
// destructive or significant action proceeds.
//
// HIG principles applied:
//   - Always describe the consequence (message), not just the action
//   - Confirm button is secondary visually — Cancel is equally prominent
//   - Destructive style (red) is opt-in; non-destructive uses primary
//
// Usage (view modifier — preferred):
//   .amachConfirmation(
//       isPresented: $showDisconnect,
//       title: "Disconnect Wallet",
//       message: "Your local data and encryption keys will be cleared...",
//       confirmLabel: "Disconnect",
//       onConfirm: { walletService.disconnect() }
//   )
//
// Usage (direct view embed):
//   AmachConfirmationSheet(
//       title: "Delete Account",
//       message: "…",
//       confirmLabel: "Delete",
//       onConfirm: deleteAccount,
//       onCancel: { showSheet = false }
//   )

struct AmachConfirmationSheet: View {
    let title: String
    let message: String
    let confirmLabel: String
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var isDestructive: Bool = true

    private var iconName: String {
        isDestructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill"
    }
    private var iconColor: Color {
        isDestructive ? Color.Amach.Semantic.error : Color.amachPrimary
    }

    var body: some View {
        VStack(spacing: AmachSpacing.xl) {
            // Drag handle
            Capsule()
                .fill(Color.amachTextTertiary.opacity(0.35))
                .frame(width: 36, height: 4)
                .padding(.top, AmachSpacing.xs)

            // Icon
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: iconName)
                    .font(.system(size: 28))
                    .foregroundStyle(iconColor)
            }

            // Copy
            VStack(spacing: AmachSpacing.sm) {
                Text(title)
                    .font(AmachType.h2)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.amachTextPrimary)
                    .multilineTextAlignment(.center)
                    .tracking(-0.2)

                Text(message)
                    .font(AmachType.body)
                    .foregroundStyle(Color.amachTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, AmachSpacing.sm)
            }

            // Actions
            VStack(spacing: AmachSpacing.sm) {
                Button(confirmLabel, action: onConfirm)
                    .buttonStyle(
                        isDestructive
                            ? AnyButtonStyle(wrapped: AmachDestructiveButtonStyle())
                            : AnyButtonStyle(wrapped: AmachPrimaryButtonStyle())
                    )

                Button("Cancel", action: onCancel)
                    .amachSecondaryButtonStyle()
            }
            .padding(.bottom, AmachSpacing.sm)
        }
        .padding(.horizontal, AmachSpacing.lg)
        .padding(.bottom, AmachSpacing.lg)
        .background(Color.amachBg)
    }
}

// Type-erasing ButtonStyle wrapper for conditional style selection
private struct AnyButtonStyle: ButtonStyle {
    let _body: (ButtonStyleConfiguration) -> AnyView

    init<S: ButtonStyle>(wrapped: S) {
        _body = { config in AnyView(wrapped.makeBody(configuration: config)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        _body(configuration)
    }
}

// Convenience modifier
extension View {
    func amachConfirmation(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmLabel: String,
        isDestructive: Bool = true,
        onConfirm: @escaping () -> Void
    ) -> some View {
        self.sheet(isPresented: isPresented) {
            AmachConfirmationSheet(
                title: title,
                message: message,
                confirmLabel: confirmLabel,
                onConfirm: {
                    isPresented.wrappedValue = false
                    onConfirm()
                },
                onCancel: { isPresented.wrappedValue = false },
                isDestructive: isDestructive
            )
            .presentationDetents([.height(420)])
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(AmachRadius.xl)
        }
    }
}


// ============================================================
// MARK: - PREVIEWS
// ============================================================

#Preview("Toast Styles") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.sm) {
            AmachToastView(
                toast: AmachToast.success("Health data synced successfully."),
                onDismiss: {}
            )
            AmachToastView(
                toast: AmachToast.warning("Sync partially completed. Some metrics missing."),
                onDismiss: {}
            )
            AmachToastView(
                toast: AmachToast.error("Upload failed. Check your connection.", action: {}, actionLabel: "Retry"),
                onDismiss: {}
            )
            AmachToastView(
                toast: AmachToast.info("Bloodwork import available in the next update."),
                onDismiss: {}
            )
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Progress Bars") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.xl) {
            AmachProgressBar(value: 0.72, label: "Uploading health data")
            AmachProgressBar(value: 0.45, label: "Data completeness", color: Color.Amach.Semantic.warning)
            AmachProgressBar(value: 1.0, showPercentage: false, color: Color.Amach.Semantic.success)
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Empty State") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        AmachEmptyState(
            icon: "waveform.path.ecg",
            title: "No trends yet",
            body: "Sync your Apple Health data and Luma will start finding patterns.",
            ctaLabel: "Sync Now",
            ctaAction: {},
            secondaryLabel: "Learn more",
            secondaryAction: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Banners") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.md) {
            AmachBanner(
                .success,
                message: "Your data was uploaded and attested on ZKsync Era.",
                isDismissed: .constant(false)
            )
            AmachBanner(
                .warning,
                message: "Last sync was 3 days ago. Your data may be out of date.",
                actionLabel: "Sync Now",
                action: {},
                isDismissed: .constant(false)
            )
            AmachBanner(
                .error,
                message: "Upload failed. Your local data is safe — tap to retry.",
                isDismissed: .constant(false)
            )
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Loading View") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        AmachLoadingView(message: "Fetching your health data…")
    }
    .preferredColorScheme(.dark)
}

#Preview("Confirmation Sheet") {
    AmachConfirmationSheet(
        title: "Disconnect Wallet",
        message: "Your local encryption keys and session data will be cleared. You can reconnect at any time.",
        confirmLabel: "Disconnect",
        onConfirm: {},
        onCancel: {},
        isDestructive: true
    )
    .preferredColorScheme(.dark)
}
