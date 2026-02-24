# iOS App Audit — Remaining Work
_Last updated: 2026-02-24_

The items below are what's left after the in-code blockers were resolved in
commit `ios-app-audit-oy9DE`.  They are ordered by severity.

---

## 🔴 BLOCKERS — must fix before any build succeeds in Xcode

### 1. No Xcode project / app target
**Status:** `Package.swift` defines a library target, not an app target.
Xcode cannot install or run a library on a device or simulator.

**Path forward — two options (pick one):**

**Option A — keep SPM, add an Xcode app target wrapper**
```
File → New → Project → iOS App
  Product Name: AmachHealth
  Bundle ID: com.amach.health
  Language: Swift / SwiftUI lifecycle

After creation:
  1. Delete the generated ContentView.swift
  2. In Xcode → Project Settings → Package Dependencies, add the local
     AmachHealth package (the folder containing Package.swift)
  3. In Build Phases → Link Binary With Libraries, add AmachHealth
  4. Set the app's Info.plist to Resources/Info.plist
  5. Set the app's entitlements to Resources/AmachHealth.entitlements
```

**Option B — convert Package.swift to a native Xcode project**
```
In Package.swift, change the library target to an executable:
  .executableTarget(name: "AmachHealth", ...)

Then open with Xcode 15+ which will generate the project natively.
Note: executable targets can't use @main — you'd use the UIApplicationMain
entrypoint or a custom entry file.
```
Option A is the lower-risk path.

---

### 2. Missing asset catalog (`.xcassets`)
**Status:** `Info.plist` references `LaunchScreenBackground` (a named color)
and `LaunchIcon` (a named image).  Neither exists in the repo.

**What to add** (minimum viable set):
```
AmachHealth/Resources/Assets.xcassets/
  AppIcon.appiconset/          ← app icon (required for App Store)
  LaunchIcon.imageset/         ← logo shown on launch screen
  LaunchScreenBackground.colorset/  ← #0A1A15 (dark) launch color
```
`LaunchScreenBackground` color:
```json
{
  "colors": [
    { "idiom": "universal",
      "color": { "color-space": "srgb",
                 "components": {"red":"0.039","green":"0.102","blue":"0.082","alpha":"1"} } }
  ]
}
```

---

### 3. `PRIVY_APP_ID` placeholder
**Status:** `WalletService.swift` line 40 falls back to `"YOUR_PRIVY_APP_ID"`
if the environment variable isn't set.  Wallet auth silently uses the wrong ID.

**Fix:**
```
Xcode → Scheme → Edit Scheme → Run → Arguments → Environment Variables
  Name:  PRIVY_APP_ID
  Value: <your app ID from dashboard.privy.io>
```
For CI, add to the build environment/secrets.

---

## 🟡 WARNINGS — won't block a build, but need attention before TestFlight

### 4. Privy iOS SDK not integrated (`WalletService.swift`)
**Status:** Wallet connect/disconnect/sign are all dev mocks.
Real on-device wallet auth will not work until the Privy iOS SDK ships
and is wired in.

**What's stubbed (lines to replace when SDK is available):**
| Line | What it does now |
|------|-----------------|
| 54–76 | Privy login + embedded wallet — commented out |
| 80–95 | Dev mock connection (address, key, signature) |
| 104–105 | Privy logout — TODO comment |
| 117–121 | Privy message signing — throws `.notImplemented` |

**Package.swift** already has the Privy dependency commented out.
When the SDK is available:
1. Uncomment the `.package(url: ...)` line in `Package.swift`
2. Replace the DEV MOCK block (lines 78–95) with the commented Privy flow above it
3. Uncomment the `Privy.shared.logout()` call in `disconnect()`
4. Replace the `throw WalletError.notImplemented` in `signMessage(_:)` with the Privy signing call

### 5. `AppState` not yet bridged to live service state
**Status:** `AppState` is now injected into the environment (fixed in this
PR).  But nothing calls `appState.setWallet()`, `appState.setHealthKit()`,
or `appState.recordSync()` when those services update at runtime.  The
initial seed in `.task { }` only runs once on launch.

**Recommended approach:** Make `WalletService` and `HealthKitService` accept
an `AppState` reference and call the bridge methods on publish:
```swift
// WalletService — in connect() / disconnect():
appState.setWallet(address: self.address)

// HealthKitService — after requestAuthorization():
appState.setHealthKit(authorized: self.isAuthorized)

// HealthDataSyncService — at end of successful sync:
appState.recordSync(tier: result.tier, score: result.score)
```
This is low-risk but requires threading `appState` into three services.

### 6. Orientation lock — portrait-only recommended
**Status:** `Info.plist` currently allows portrait + both landscape orientations.
The app's layout (tab bar, FAB, chat input) is designed for portrait.
Landscape was likely left in by default.

**Fix:** Remove `UIInterfaceOrientationLandscapeLeft` and
`UIInterfaceOrientationLandscapeRight` from `UISupportedInterfaceOrientations`
in `Info.plist` (keep the iPad `~ipad` key as-is if iPad support is intended).

### 7. `preferredColorScheme(.dark)` forced globally
**Status:** `AmachHealthApp.swift` forces dark mode app-wide.
Light mode (amber/cream gradient) is defined in the design system but never
shown in-app.

**Options:**
- Keep forced dark if dark-only is the intended v1 stance
- Remove the modifier and let the OS control it (design system already has
  both color scheme implementations)

---

## 🟢 DEFERRED / INTENTIONAL (no action needed now)

### 8. Test TODOs
- `APIClientTests.swift` lines 326–331: 6 integration tests marked TODO.
  Core SSE parsing tests exist and pass.
- `ChatServiceTests.swift` lines 247–250: 3 simulator-only streaming tests.
- `HealthKitMappingTests.swift` line 367: 1 device-only test.

All are intentionally deferred.  Run `swift test` from the package root to
verify existing tests pass.

### 9. `signMessage` throws `.notImplemented` in key derivation path
`deriveEncryptionKey()` calls `signMessage()` which throws.  This means
`deriveEncryptionKey()` also always throws.  In the current dev mock flow,
`deriveEncryptionKey()` is never called — the dev key is constructed
directly.  Once Privy signs in, both functions will work together.  No
action needed until then.

---

## Checklist for TestFlight readiness

- [ ] Xcode app target created (item 1)
- [ ] `.xcassets` with AppIcon, LaunchIcon, LaunchScreenBackground (item 2)
- [ ] `PRIVY_APP_ID` set in scheme / CI environment (item 3)
- [ ] Privy iOS SDK integrated (item 4)
- [ ] AppState bridged to live service events (item 5)
- [ ] Orientation lock confirmed intentional (item 6)
- [ ] `preferredColorScheme` decision made (item 7)
