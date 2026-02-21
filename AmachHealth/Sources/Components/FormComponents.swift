// FormComponents.swift
// AmachHealth
//
// Form input components and extended button styles.
// All minimum touch targets: 44×44pt (AmachAccessibility.minTouchTarget).
//
// Components:
//   AmachTertiaryButtonStyle   — text/link button, no chrome
//   AmachDestructiveButtonStyle— red fill, for irreversible actions
//   AmachTextField             — styled text input with icon + error state
//   AmachSecureField           — password input with reveal toggle
//   AmachToggleStyle           — emerald custom toggle
//   AmachCheckbox              — checkmark selection control
//   AmachSegmentedControl      — period/category picker (7D / 30D / 90D)
//   AmachFormSection           — titled wrapper for input groups

import SwiftUI


// ============================================================
// MARK: - TERTIARY BUTTON STYLE (Link / Low-Emphasis)
// ============================================================
//
// No background, no border. Just the label in primary color.
// Use for low-stakes secondary actions: "Skip", "Learn more",
// "Cancel" in non-destructive contexts.
//
// Usage:
//   Button("Skip for now", action: skip)
//       .amachTertiaryButtonStyle()

struct AmachTertiaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AmachType.caption)
            .fontWeight(.semibold)
            .foregroundStyle(Color.amachPrimary)
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .animation(
                AmachAnimation.ifMotion(AmachAnimation.fast),
                value: configuration.isPressed
            )
            .frame(minHeight: AmachAccessibility.minTouchTarget)
    }
}


// ============================================================
// MARK: - DESTRUCTIVE BUTTON STYLE
// ============================================================
//
// Red-filled CTA for irreversible, data-destroying actions.
// Always pair with AmachConfirmationSheet before the action fires.
//
// Usage:
//   Button("Delete Account", action: deleteAccount)
//       .amachDestructiveButtonStyle()

struct AmachDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AmachType.h3)
            .fontWeight(.semibold)
            .padding(.horizontal, AmachSpacing.lg)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Color.Amach.Semantic.error)
            .foregroundStyle(Color.Amach.Text.onPrimary)
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.md))
            .shadow(color: Color.Amach.Semantic.error.opacity(0.28), radius: 8, y: 2)
            .scaleEffect(configuration.isPressed ? AmachAnimation.buttonPressScale : 1)
            .animation(
                AmachAnimation.ifMotion(AmachAnimation.spring),
                value: configuration.isPressed
            )
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { AmachHaptics.buttonPress() }
            }
    }
}

extension View {
    func amachTertiaryButtonStyle() -> some View {
        buttonStyle(AmachTertiaryButtonStyle())
    }
    func amachDestructiveButtonStyle() -> some View {
        buttonStyle(AmachDestructiveButtonStyle())
    }
}


// ============================================================
// MARK: - AMACH TEXT FIELD
// ============================================================
//
// Emerald focus ring. Icon support. Error state with inline message.
// Clear button appears when the field has content.
//
// Usage:
//   AmachTextField("Email address", text: $email, icon: "envelope")
//   AmachTextField("Display name", text: $name, errorMessage: nameError)

struct AmachTextField: View {
    let placeholder: String
    @Binding var text: String

    var icon: String?               = nil
    var errorMessage: String?       = nil
    var keyboardType: UIKeyboardType            = .default
    var textContentType: UITextContentType?     = nil
    var autocapitalization: TextInputAutocapitalization = .sentences
    var onSubmit: (() -> Void)?     = nil

    @FocusState private var isFocused: Bool

    private var borderColor: Color {
        if errorMessage != nil    { return Color.Amach.Semantic.error }
        if isFocused              { return Color.amachPrimary }
        return Color.amachPrimary.opacity(0.20)
    }

    private var borderWidth: CGFloat {
        (isFocused || errorMessage != nil) ? 1.5 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.xs) {
            HStack(spacing: AmachSpacing.sm) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(
                            isFocused ? Color.amachPrimary : Color.amachTextSecondary
                        )
                        .frame(width: 20)
                        .animation(AmachAnimation.fast, value: isFocused)
                }

                TextField(placeholder, text: $text)
                    .font(AmachType.body)
                    .foregroundStyle(Color.amachTextPrimary)
                    .keyboardType(keyboardType)
                    .textContentType(textContentType)
                    .textInputAutocapitalization(autocapitalization)
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }

                if !text.isEmpty {
                    Button {
                        text = ""
                        AmachHaptics.toggle()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.amachTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, AmachSpacing.md)
            .padding(.vertical, 14)
            .background(Color.amachSurface)
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AmachRadius.sm)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .animation(AmachAnimation.ifMotion(AmachAnimation.fast), value: isFocused)
            .animation(AmachAnimation.ifMotion(AmachAnimation.fast), value: errorMessage != nil)

            if let error = errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                    Text(error)
                        .font(AmachType.tiny)
                }
                .foregroundStyle(Color.Amach.Semantic.error)
                .padding(.leading, AmachSpacing.xs)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(AmachAnimation.ifMotion(AmachAnimation.fast), value: errorMessage)
    }
}


// ============================================================
// MARK: - AMACH SECURE FIELD
// ============================================================
//
// Password / sensitive data input with show/hide eye toggle.
// Mirrors AmachTextField styling exactly.
//
// Usage:
//   AmachSecureField("Passphrase", text: $passphrase)
//   AmachSecureField("Password", text: $pw, errorMessage: pwError)

struct AmachSecureField: View {
    let placeholder: String
    @Binding var text: String

    var icon: String?         = "lock.fill"
    var errorMessage: String? = nil

    @FocusState private var isFocused: Bool
    @State private var isRevealed = false

    private var borderColor: Color {
        if errorMessage != nil { return Color.Amach.Semantic.error }
        if isFocused           { return Color.amachPrimary }
        return Color.amachPrimary.opacity(0.20)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.xs) {
            HStack(spacing: AmachSpacing.sm) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(
                            isFocused ? Color.amachPrimary : Color.amachTextSecondary
                        )
                        .frame(width: 20)
                }

                Group {
                    if isRevealed {
                        TextField(placeholder, text: $text)
                            .focused($isFocused)
                    } else {
                        SecureField(placeholder, text: $text)
                            .focused($isFocused)
                    }
                }
                .font(AmachType.body)
                .foregroundStyle(Color.amachTextPrimary)
                .textContentType(.password)

                Button {
                    isRevealed.toggle()
                    AmachHaptics.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.amachTextTertiary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AmachSpacing.md)
            .padding(.vertical, 14)
            .background(Color.amachSurface)
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AmachRadius.sm)
                    .stroke(borderColor, lineWidth: (isFocused || errorMessage != nil) ? 1.5 : 1)
            )
            .animation(AmachAnimation.ifMotion(AmachAnimation.fast), value: isFocused)

            if let error = errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11))
                    Text(error)
                        .font(AmachType.tiny)
                }
                .foregroundStyle(Color.Amach.Semantic.error)
                .padding(.leading, AmachSpacing.xs)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(AmachAnimation.ifMotion(AmachAnimation.fast), value: errorMessage)
    }
}


// ============================================================
// MARK: - AMACH TOGGLE STYLE
// ============================================================
//
// Custom toggle: emerald fill on active, muted gray when off.
// Behaves identically to the native iOS toggle; swaps brand color.
//
// Usage:
//   Toggle("Push Notifications", isOn: $notificationsOn)
//       .amachToggleStyle()

struct AmachToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
                .font(AmachType.body)
                .foregroundStyle(Color.amachTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Track + thumb
            RoundedRectangle(cornerRadius: AmachRadius.pill)
                .fill(
                    configuration.isOn
                        ? Color.amachPrimary
                        : Color.amachTextSecondary.opacity(0.25)
                )
                .frame(width: 51, height: 31)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .frame(width: 27, height: 27)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .offset(x: configuration.isOn ? 10 : -10)
                )
                .animation(
                    AmachAnimation.ifMotion(AmachAnimation.spring),
                    value: configuration.isOn
                )
                .onTapGesture {
                    configuration.isOn.toggle()
                    AmachHaptics.toggle()
                }
        }
        .frame(minHeight: AmachAccessibility.minTouchTarget)
        .contentShape(Rectangle())
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

extension View {
    func amachToggleStyle() -> some View {
        toggleStyle(AmachToggleStyle())
    }
}


// ============================================================
// MARK: - AMACH CHECKBOX
// ============================================================
//
// Checkmark control for multi-select contexts:
// consent flows, metric selection, filter pickers.
//
// Supports an optional description line below the label.
//
// Usage:
//   AmachCheckbox("Sync heart rate data", isChecked: $syncHR)
//   AmachCheckbox(
//       "I agree to the terms",
//       description: "Your data stays encrypted and under your control.",
//       isChecked: $agreedToTerms
//   )

struct AmachCheckbox: View {
    let label: String
    @Binding var isChecked: Bool
    var description: String? = nil

    var body: some View {
        Button {
            isChecked.toggle()
            AmachHaptics.toggle()
        } label: {
            HStack(alignment: description != nil ? .top : .center, spacing: AmachSpacing.sm) {
                // Checkbox square
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isChecked ? Color.amachPrimary : Color.clear)
                        .frame(width: 22, height: 22)

                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            isChecked ? Color.amachPrimary : Color.amachPrimary.opacity(0.35),
                            lineWidth: 1.5
                        )
                        .frame(width: 22, height: 22)

                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.Amach.Text.onPrimary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(
                    AmachAnimation.ifMotion(AmachAnimation.spring),
                    value: isChecked
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(AmachType.body)
                        .foregroundStyle(Color.amachTextPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if let desc = description {
                        Text(desc)
                            .font(AmachType.caption)
                            .foregroundStyle(Color.amachTextSecondary)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: AmachAccessibility.minTouchTarget)
        .accessibilityLabel(label + (description.map { ". " + $0 } ?? ""))
        .accessibilityValue(isChecked ? "Checked" : "Unchecked")
        .accessibilityAddTraits(.isButton)
    }
}


// ============================================================
// MARK: - AMACH SEGMENTED CONTROL
// ============================================================
//
// Custom pill-style segmented picker with emerald active tab.
// Use for period selectors (7D / 30D / 90D) and category pickers.
//
// T must be Hashable and CustomStringConvertible so each option
// can render its own label via `.description`.
//
// Usage:
//   AmachSegmentedControl(selection: $period, options: TrendPeriod.allCases)
//   AmachSegmentedControl(selection: $category, options: HealthCategory.allCases)

struct AmachSegmentedControl<T: Hashable & CustomStringConvertible>: View {
    @Binding var selection: T
    let options: [T]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option

                Button {
                    guard selection != option else { return }
                    selection = option
                    AmachHaptics.toggle()
                } label: {
                    Text(option.description)
                        .font(AmachType.tiny)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(
                            isSelected
                                ? Color.Amach.Text.onPrimary
                                : Color.amachTextSecondary
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AmachSpacing.sm)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: AmachRadius.sm - 2)
                                        .fill(Color.amachPrimary)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .animation(
                    AmachAnimation.ifMotion(AmachAnimation.fast),
                    value: isSelected
                )
            }
        }
        .padding(3)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AmachRadius.sm)
                .stroke(Color.amachPrimary.opacity(0.15), lineWidth: 1)
        )
    }
}


// ============================================================
// MARK: - FORM SECTION WRAPPER
// ============================================================
//
// Groups related inputs under a title + optional description.
// Use inside List/Form or standalone VStack layouts.
//
// Usage:
//   AmachFormSection("Sync Range", description: "Choose the time window to upload.") {
//       DatePicker(…)
//   }

struct AmachFormSection<Content: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AmachType.h3)
                    .foregroundStyle(Color.amachTextPrimary)

                if let desc = description {
                    Text(desc)
                        .font(AmachType.caption)
                        .foregroundStyle(Color.amachTextSecondary)
                        .lineSpacing(3)
                }
            }

            content()
        }
    }
}


// ============================================================
// MARK: - PREVIEWS
// ============================================================

#Preview("Buttons") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.md) {
            Button("Primary Action") {}
                .amachPrimaryButtonStyle()
            Button("Secondary Action") {}
                .amachSecondaryButtonStyle()
            Button("Skip for now") {}
                .amachTertiaryButtonStyle()
            Button("Delete Account") {}
                .amachDestructiveButtonStyle()
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Text Fields") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.md) {
            AmachTextField("Email address", text: .constant(""), icon: "envelope")
            AmachTextField(
                "Name",
                text: .constant("Dave"),
                icon: "person.fill",
                errorMessage: "Display name is required"
            )
            AmachSecureField("Passphrase", text: .constant(""))
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Toggles & Checkboxes") {
    ZStack {
        Color.amachBg.ignoresSafeArea()
        VStack(spacing: AmachSpacing.lg) {
            Toggle("Push Notifications", isOn: .constant(true))
                .amachToggleStyle()
            Toggle("Background Sync", isOn: .constant(false))
                .amachToggleStyle()

            Divider().padding(.vertical, AmachSpacing.xs)

            AmachCheckbox("Sync heart rate data", isChecked: .constant(true))
            AmachCheckbox(
                "I agree to the data terms",
                description: "Your data stays encrypted and under your control.",
                isChecked: .constant(false)
            )
        }
        .padding()
    }
    .preferredColorScheme(.dark)
}

#Preview("Segmented Control") {
    enum Period: String, CaseIterable, Hashable, CustomStringConvertible {
        case week = "7D", month = "30D", quarter = "90D"
        var description: String { rawValue }
    }

    @Previewable @State var selection: Period = .week

    return ZStack {
        Color.amachBg.ignoresSafeArea()
        AmachSegmentedControl(selection: $selection, options: Period.allCases)
            .padding()
    }
    .preferredColorScheme(.dark)
}
