# Computer Use Skill — AmachHealth iOS App

Use Claude's computer use capabilities to visually test and debug the AmachHealth iOS app running in the Xcode Simulator.

## Prerequisites

Build and launch the app in the simulator before starting:

```bash
# Build and run on iPhone 15 Pro simulator
xcodebuild -scheme AmachHealth -destination 'platform=iOS Simulator,name=iPhone 15 Pro' -configuration Debug build

# Or open in Xcode and press ▶ Run
open AmachHealth.xcodeproj
```

## What This Skill Does

This skill enables Claude to:
- Take screenshots of the iOS simulator
- Navigate between app screens and interact with UI elements
- Visually verify Luma AI chat, health dashboards, and onboarding flows
- Identify UI bugs, layout issues, or regressions

## App Structure — Key Screens

| Screen | Description |
|--------|-------------|
| Onboarding | First-run flow — wallet connection, HealthKit permissions |
| Dashboard | Health score ring, daily metrics grid (steps, HRV, sleep, etc.) |
| Luma Chat | AI companion chat interface (indigo theme, `#6366F1`) |
| Timeline | Life events and health milestones |
| Trends | Historical metric charts (sparklines, sleep stages, HR zones) |
| Profile | Settings, wallet info, Storj storage details |

## Common Tasks

### Visual snapshot of current screen
Take a screenshot of the simulator and describe the visible UI elements, layout, and state.

### Navigate between main tabs
1. Screenshot the tab bar
2. Tap each tab (Dashboard, Chat, Timeline, Trends, Profile)
3. Screenshot each screen and verify content loads correctly

### Test Luma AI chat
1. Navigate to the Chat tab
2. Tap the message input field
3. Type a health question (e.g. "How did I sleep last night?")
4. Tap Send and screenshot the response bubble
5. Verify the indigo Luma styling is applied correctly (indigo is **strictly reserved for Luma/AI only**)

### Verify Dashboard metrics
1. Navigate to the Dashboard tab
2. Screenshot the health score ring (GOLD/SILVER/BRONZE/NONE tier badge)
3. Screenshot the metrics grid and verify all available metrics display with correct units
4. Tap a metric card to open MetricDetailView and verify the detail screen

### Test onboarding flow (fresh install simulation)
1. Reset the simulator to clear app data: `Device → Erase All Content and Settings`
2. Launch the app
3. Screenshot each onboarding step
4. Do **not** connect a real wallet — verify UI state only

### Check dark mode and light mode
1. Toggle appearance in Simulator: `Features → Toggle Appearance`
2. Screenshot the Dashboard in both modes
3. Verify:
   - Dark mode uses green-tinted surfaces (`#0A1A15` background)
   - Light mode uses amber/cream gradient
   - Indigo (`#6366F1`) is used **only** for Luma/AI elements

## Tech Context

- **Framework:** SwiftUI, iOS 17+, MVVM pattern
- **AI companion:** Luma — indigo theme, sparkles icon
- **Health data:** Apple HealthKit (35+ metric types)
- **Auth:** Privy iOS SDK (wallet-based)
- **Encryption:** CryptoKit (AES-256)
- **Backend:** Next.js API (amach-website) for AI agents, Storj storage, ZKsync attestations
- **Design tokens:** All defined in `Sources/DesignSystem/AmachDesignSystem.swift`

## Safety Guidelines

- Do **not** connect real wallets or sign real transactions
- Do **not** grant HealthKit access to real health data during automated tests — use mock data
- Use the ZKsync Era Sepolia **testnet** only if blockchain interactions are needed
- Treat screenshots containing health data as sensitive — do not share outside the dev team
- The indigo colour (`#6366F1`) must **only** appear on Luma/AI elements — flag any violation

## Reporting Issues

When you identify a visual bug or unexpected behaviour:
1. Take a screenshot showing the issue
2. Note the screen name, device model, and iOS version in the simulator
3. Note whether it occurs in dark mode, light mode, or both
4. Describe the expected vs actual appearance
5. Check `Sources/Views/` or `Sources/Components/` for the relevant file and suggest a fix
