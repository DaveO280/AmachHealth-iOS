# Amach Health — iOS Project Context

## What Is Amach Health

Decentralized health data protocol. Users upload and sync health data (Apple Health, bloodwork, DEXA, CGM), receive AI-powered analysis from **Luma** (in-app health intelligence companion). Users own their data: encrypted storage on Storj, blockchain-verified profiles on ZKsync Era, value flows back to users who generated it.

**Status:** Live web app. iOS app in active development. First grant received.

---

## Brand

| | |
|---|---|
| **Name** | Amach Health — "Amach" = Outsider/Rebellion in Gaelic |
| **AI companion** | Luma ("light/clarity") — companion archetype, sparkles icon, indigo theme, tagline "AI health companion" |
| **Logo** | White AH lettermark on emerald circle |
| **Archetype** | The Sage meets The Outlaw — principled defiance, not punk |
| **Tone** | Minimal, confident, slightly rebellious. Direct language. |
| **Principles** | "Clarity Over Cleverness" / "Your Data, Your Health" / "Driven by Data, Guided by Nature" |
| **Design philosophy** | "Earthy palette, modern execution" — glassmorphism, gradient borders, layered elevation |
| **Target audience** | Health-conscious tech-forward adults 25–45. Apple Watch/Oura/CGM users. High design literacy (Notion/Linear/Arc). Care about data ownership. Comfortable with crypto/web3. |

**Social:** X @amachhealth / LinkedIn (founder personal) / Website: amachhealth.com

---

## Color System

### Core Palette

| Token | Hex | Usage |
|---|---|---|
| `primary` | `#006B4F` | Emerald anchor, scale p50–p700 |
| `accent` | `#F59E0B` | Amber accent (`#D97706` for text on light bg) |
| `ai` / Luma | `#6366F1` indigo-500 | **Luma/AI only** — never use for non-AI elements |
| `ai-bubble-light` | `#EEF2FF` | Luma chat bubble (light mode) |
| `ai-bubble-dark` | `#3730A3` | Luma chat bubble (dark mode) |

### Semantic

| | Hex |
|---|---|
| success | `#10B981` |
| warning | `#F59E0B` |
| error | `#EF4444` |
| info | `#3B82F6` |
| optimal | `#059669` |
| borderline | `#D97706` |
| critical | `#DC2626` |

### Surfaces

**Dark mode** (green-tinted, hue ~155° — NOT generic navy/gray):
- bg: `#0A1A15` / surface: `#111F1A` / elevated: `#1A2E26`

**Light mode** (gold/amber/cream — NOT mist green):
- Body: `linear-gradient(160deg, #FFFBEB 0%, #FEF3C7 30%, #FFFDE7 65%, #FFFFFF 100%)` fixed
- `--bg: #FFFBEB` / `--surface: #FFFFFF` / `--surface-elev: #FEF3C7`
- Text: `#064E3B` (deep emerald, NOT generic gray)

**Tier palette:** Gold / Silver / Bronze / None — each has dedicated bg + text + border tokens.

> **Rule:** Indigo (`#6366F1`) is strictly Luma/AI-only. Do not use for non-AI UI elements.

---

## iOS Design System (`AmachDesignSystem.swift`)

### Typography

| | Size | Weight | Notes |
|---|---|---|---|
| Wordmark / companyName | 32pt | Inter ExtraBold | |
| h1 | 28pt | Bold | |
| h2 | 20pt | Semibold | |
| h3 | 16pt | Semibold | |
| body | 16pt | Regular | |
| caption | 14pt | Regular | |
| tiny | 12pt | Medium | |
| Biomarker values | — | SF Mono Bold | Fixed size, no Dynamic Type |
| Biomarker units | — | SF Mono Regular | |

### Spacing (4pt base grid)

`xs 4 / sm 8 / md 16 / lg 24 / xl 32 / xxl 48 / xxxl 64`

Named: `cardPadding 24` / `cardGap 16` / `sectionSpacing 32` / `screenEdge 16` / `chatMsgSpacing 16` / `chatMsgSpacingLg 24`

### Corner Radius

`xs 6 / sm 10 / md 14 / card 16 / lg 20 / xl 24 / pill 100`

### Animation

| Token | Value |
|---|---|
| fast | 0.15s easeOut |
| normal | 0.25s easeOut |
| slow | 0.40s easeInOut |
| spring | response 0.3, dampingFraction 0.7 |
| sheetSpring | response 0.35, dampingFraction 0.85 |
| cardPressScale | 0.97 |
| buttonPressScale | 0.96 |
| Luma typing dot | 0.6s cycle, 0.15s stagger between dots |

### Haptics

| Trigger | Haptic |
|---|---|
| Card tap | light |
| Button | medium |
| Success / error | notification |
| Toggle | selection |
| Luma response | light |

### Elevation (3 levels)

- **Level 1 (base):** MetricCard, list rows — shadow 10%, y:2, r:8
- **Level 2 (raised):** Featured cards, Luma FAB — shadow 18%, glass blur 16
- **Level 3 (floating):** Modals, half-sheets — shadow 30%, glass blur 24
- **AI gradient border:** Primary→AI.base at 135° (Luma insights only)

---

## iOS App Architecture

**Pattern:** Pure SwiftUI, iOS 17+, MVVM

### Views
- `ChatView` — Luma AI chat interface
- `DashboardView` — health score ring, 2-col metric grid, trend charts (week/month/3-month), monospace bold values
- `HealthSyncView` — HealthKit + Wallet connection status, sync progress, date picker, stored data list, tier result display

### Key Services

| Component | File | Description |
|---|---|---|
| `HealthKitService` | `Services/HealthKitService.swift` | 35+ metric types, daily aggregation, completeness scoring |
| `WalletService` | `Services/WalletService.swift` | Privy SDK integration, encryption key derivation |
| `AmachAPIClient` | `API/AmachAPIClient.swift` | Backend API client (shared routes with web) |
| `HealthDataSyncService` | `Services/HealthDataSyncService.swift` | Full sync orchestration, background support |
| `ChatService` | `ChatService.shared` | Singleton — local JSON persistence + batched Storj sync every 10 messages. History: 18 messages (9 exchanges). Current session + 30 archived. |

### iOS Tech Stack

- SwiftUI, iOS 17+, MVVM
- HealthKit (on-device)
- Privy (auth/wallet)
- CryptoKit (encryption)
- Hits existing Next.js API backend for business logic, AI, storage, blockchain

---

## Web App Architecture

**Stack:** Next.js 16 / TypeScript / Tailwind + shadcn/ui / React Context

- 6 specialized AI agents (Venice AI multi-agent)
- Storj (encrypted storage)
- ZKsync Era (blockchain attestations)
- Privy (auth)

**Related repo:** [Amach-Website](https://github.com/DaveO280/Amach-Website)

---

## Backend API (shared iOS ↔ web)

| Endpoint | Action | Description |
|---|---|---|
| `POST /api/storj` | `storage/store` | Upload encrypted health data |
| `POST /api/storj` | `storage/list` | List stored health data |
| `POST /api/storj` | `storage/retrieve` | Retrieve and decrypt data |
| `POST /api/health/summary` | — | Health summary for AI |
| `POST /api/attestations` | — | User's attestations |

---

## Development Notes

- All design tokens in `AmachDesignSystem.swift` map 1:1 to the HTML/CSS preview files in `ios-preview/`
- `ios-preview/design-system.html` is the canonical design reference
- `ios-preview/index.html` is the interactive app preview — defaults to light mode with the amber/cream gradient background
- Dark mode uses green-tinted surfaces exclusively — never navy, never generic gray
- Indigo (`#6366F1`) is reserved for Luma AI interactions only throughout the entire UI
