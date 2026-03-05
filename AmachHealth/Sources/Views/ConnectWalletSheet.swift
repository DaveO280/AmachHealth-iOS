// ConnectWalletSheet.swift
// AmachHealth
//
// Two-step email OTP sheet for connecting a Privy embedded wallet.
// Matches the web app's loginMethods: ["email"] — no Apple/Google OAuth.
//
// Flow:
//   Step 1: User enters email → taps "Send Code" → privy.email.sendCode(to:)
//   Step 2: User enters 6-digit OTP → taps "Verify" → privy.email.loginWithCode(_:sentTo:)
//   On success: wallet.isConnected becomes true → sheet auto-dismisses

import SwiftUI

struct ConnectWalletSheet: View {
    @EnvironmentObject private var wallet: WalletService
    @Environment(\.dismiss) private var dismiss

    private enum LoginStep { case email, code }

    @State private var step: LoginStep = .email
    @State private var emailInput = ""
    @State private var codeInput = ""
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachSurface.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Icon + title
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.amachPrimary.opacity(0.12))
                                .frame(width: 64, height: 64)
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Color.amachPrimaryBright)
                        }
                        .padding(.top, 32)

                        Text(step == .email ? "Connect Your Wallet" : "Check Your Email")
                            .font(AmachType.h2)
                            .foregroundStyle(Color.amachTextPrimary)

                        Text(step == .email
                             ? "Enter the email you use on amachhealth.com"
                             : "Enter the 6-digit code sent to\n\(emailInput)")
                            .font(AmachType.caption)
                            .foregroundStyle(Color.amachTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.bottom, 32)

                    // Input + action
                    VStack(spacing: 16) {
                        if step == .email {
                            emailStep
                        } else {
                            codeStep
                        }

                        // Error message
                        if let err = wallet.error {
                            Text(err)
                                .font(AmachType.tiny)
                                .foregroundStyle(Color.amachDestructive)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer()

                    // Footer
                    Text("Your data stays private. We never store passwords.")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 24)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
        }
        // Auto-dismiss when wallet connects
        .onChange(of: wallet.isConnected) { _, connected in
            if connected { dismiss() }
        }
    }

    // MARK: - Step 1: Email Input

    private var emailStep: some View {
        VStack(spacing: 12) {
            TextField("you@example.com", text: $emailInput)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($emailFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.amachElevated)
                .clipShape(RoundedRectangle(cornerRadius: AmachRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: AmachRadius.md)
                        .strokeBorder(Color.amachPrimary.opacity(0.18), lineWidth: 1)
                )
                .font(AmachType.body)
                .foregroundStyle(Color.amachTextPrimary)
                .onAppear { emailFocused = true }

            primaryButton(
                title: "Send Code",
                isLoading: wallet.isLoading,
                isEnabled: isValidEmail(emailInput)
            ) {
                Task {
                    do {
                        try await wallet.sendEmailCode(to: emailInput.trimmingCharacters(in: .whitespaces))
                        withAnimation(.easeInOut(duration: 0.25)) { step = .code }
                    } catch {
                        // wallet.error is set by the service
                    }
                }
            }
        }
    }

    // MARK: - Step 2: Code Input

    private var codeStep: some View {
        VStack(spacing: 12) {
            TextField("123456", text: $codeInput)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($codeFocused)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.amachElevated)
                .clipShape(RoundedRectangle(cornerRadius: AmachRadius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: AmachRadius.md)
                        .strokeBorder(Color.amachPrimary.opacity(0.18), lineWidth: 1)
                )
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.amachTextPrimary)
                .onChange(of: codeInput) { _, val in
                    // Enforce max 6 digits
                    if val.count > 6 { codeInput = String(val.prefix(6)) }
                }
                .onAppear { codeFocused = true }

            primaryButton(
                title: "Verify Code",
                isLoading: wallet.isLoading,
                isEnabled: codeInput.count == 6
            ) {
                Task {
                    do {
                        try await wallet.loginWithEmailCode(codeInput)
                        // dismiss() is called via .onChange(of: wallet.isConnected)
                    } catch {
                        // wallet.error is set by the service
                    }
                }
            }

            // Back to email step
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    codeInput = ""
                    wallet.error = nil
                    step = .email
                }
            } label: {
                Label("Use a different email", systemImage: "chevron.left")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextSecondary)
            }
        }
    }

    // MARK: - Shared Button

    private func primaryButton(
        title: String,
        isLoading: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(title)
                        .font(AmachType.body.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(isEnabled ? Color.amachPrimary : Color.amachPrimary.opacity(0.4))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.md))
        }
        .disabled(!isEnabled || isLoading)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
    }

    // MARK: - Helpers

    private func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") && trimmed.contains(".") && trimmed.count > 4
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ConnectWalletSheet()
        .environmentObject(WalletService.shared)
}
#endif
