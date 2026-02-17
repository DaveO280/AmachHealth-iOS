# Amach Health - iOS App

Native iOS app for syncing Apple Health data to Storj with on-chain attestations.

## Quick Start

```bash
# Clone this repo
git clone https://github.com/DaveO280/AmachHealth-iOS.git
cd AmachHealth-iOS

# Open in Xcode
open AmachHealth.xcodeproj

# Or build from command line
xcodebuild -scheme AmachHealth -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Project Structure

```
AmachHealth-iOS/
├── README.md
├── DESIGN-SYSTEM.md              # Shared design tokens (synced with web)
├── AmachHealth/
│   ├── Package.swift             # Swift Package Manager config
│   ├── Sources/
│   │   ├── App/
│   │   │   └── AmachHealthApp.swift    # App entry point
│   │   ├── Models/
│   │   │   └── HealthDataTypes.swift   # Shared data types
│   │   ├── Services/
│   │   │   ├── HealthKitService.swift  # HealthKit integration
│   │   │   ├── WalletService.swift     # Privy wallet
│   │   │   └── HealthDataSyncService.swift
│   │   ├── API/
│   │   │   └── AmachAPIClient.swift    # Backend API client
│   │   └── Views/
│   │       └── HealthSyncView.swift    # Main sync UI
│   └── Resources/
│       ├── Info.plist
│       └── AmachHealth.entitlements
└── Tests/
```

## Architecture

### Data Flow

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  HealthKit  │ ──▶ │ HealthKitService │ ──▶ │ HealthDataSync  │
└─────────────┘     └──────────────────┘     └────────┬────────┘
                                                      │
                                                      ▼
┌─────────────┐     ┌──────────────────┐     ┌─────────────────┐
│  On-chain   │ ◀── │   /api/storj     │ ◀── │ AmachAPIClient  │
│ Attestation │     │   (Backend)      │     └─────────────────┘
└─────────────┘     └──────────────────┘
                            │
                            ▼
                    ┌─────────────────┐
                    │ Storj (encrypted)│
                    └─────────────────┘
```

### Key Components

| Component                 | File                                   | Description                                               |
| ------------------------- | -------------------------------------- | --------------------------------------------------------- |
| **HealthKitService**      | `Services/HealthKitService.swift`      | 35+ metric types, daily aggregation, completeness scoring |
| **WalletService**         | `Services/WalletService.swift`         | Privy SDK integration, encryption key derivation          |
| **AmachAPIClient**        | `API/AmachAPIClient.swift`             | Backend API client (same routes as web)                   |
| **HealthDataSyncService** | `Services/HealthDataSyncService.swift` | Full sync orchestration, background support               |

## Setup

### Prerequisites

- Xcode 15+
- iOS 17+ deployment target
- Apple Developer account (for HealthKit entitlements)
- Privy App ID (from [privy.io](https://privy.io))

### 1. Configure Signing

1. Open project in Xcode
2. Select the AmachHealth target
3. Go to "Signing & Capabilities"
4. Select your development team
5. Update bundle identifier if needed

### 2. Environment Variables

Create `Config.xcconfig` or set in scheme:

```
AMACH_API_URL = https://app.amach.health
PRIVY_APP_ID = your_privy_app_id
```

### 3. Add HealthKit Capability

The entitlements file is pre-configured, but verify in Xcode:

- HealthKit
- HealthKit (Clinical Health Records) - optional
- Background Modes: Background fetch, Background processing

## API Compatibility

Uses the same backend as the web app:

| Endpoint                   | Action             | Description                  |
| -------------------------- | ------------------ | ---------------------------- |
| `POST /api/storj`          | `storage/store`    | Upload encrypted health data |
| `POST /api/storj`          | `storage/list`     | List stored health data      |
| `POST /api/storj`          | `storage/retrieve` | Retrieve and decrypt data    |
| `POST /api/health/summary` | -                  | Get health summary for AI    |
| `POST /api/attestations`   | -                  | Get user's attestations      |

## Data Format

Identical to web app for cross-platform compatibility:

```json
{
  "manifest": {
    "version": 1,
    "exportDate": "2025-02-17",
    "dateRange": { "start": "2024-02-17", "end": "2025-02-17" },
    "metricsPresent": ["StepCount", "HeartRate", "Sleep", ...],
    "completeness": {
      "score": 85,
      "tier": "GOLD",
      "coreComplete": true,
      "daysCovered": 365,
      "recordCount": 50000
    },
    "sources": { "watch": 60, "phone": 35, "other": 5 }
  },
  "dailySummaries": {
    "2025-02-17": {
      "StepCount": { "total": 10000, "count": 1 },
      "HeartRate": { "avg": 72, "min": 55, "max": 120, "count": 1440 },
      "sleep": { "total": 420, "deep": 90, "rem": 100, "core": 200, "awake": 30 }
    }
  }
}
```

## Metrics Supported

### Core Metrics (required for tier)

- Steps, Heart Rate, HRV, Resting HR
- Sleep Analysis (stages: deep, REM, core, awake)
- Active Energy, Exercise Time
- VO2 Max, Respiratory Rate

### Extended Metrics

- Body measurements (weight, body fat, BMI)
- Activity (distance, flights climbed, stand time)
- Vitals (blood pressure, SpO2, temperature)
- Nutrition (calories, macros, water, caffeine)
- Workouts (all activity types)

## Building & Testing

### Debug Build

```bash
xcodebuild -scheme AmachHealth -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Release Build

```bash
xcodebuild -scheme AmachHealth -configuration Release \
  -destination 'generic/platform=iOS'
```

### Run Tests

```bash
xcodebuild test -scheme AmachHealth \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

## App Store Submission

### Required Screenshots

- 6.7" (iPhone 15 Pro Max): 1290 x 2796
- 6.5" (iPhone 14 Plus): 1284 x 2778
- 5.5" (iPhone 8 Plus): 1242 x 2208

### App Store Connect Checklist

- [ ] App icon (1024x1024)
- [ ] Screenshots for all required sizes
- [ ] Privacy policy URL
- [ ] HealthKit usage descriptions reviewed
- [ ] Background modes justified
- [ ] Export compliance (encryption)

## Dependencies

- **HealthKit** (Apple) - Health data access
- **Privy iOS SDK** - Wallet management
- **CryptoKit** (Apple) - Encryption

## Related

- [Web App](https://github.com/DaveO280/Amach-Website) - React/Next.js web app
- [Design System](./DESIGN-SYSTEM.md) - Shared design tokens
