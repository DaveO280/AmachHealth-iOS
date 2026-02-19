# Amach Health Design System

Shared design tokens and guidelines for web and iOS apps.

> **Theme:** Dark/premium. The iOS app is a dark-mode-only experience.
> Web app CSS variables (`globals.css`) are the source of truth — iOS tokens are derived from those same HSL values.

---

## Colors

### Brand Colors (Dark Theme)

These match the web app's dark-mode CSS custom properties exactly.

| Name | iOS Hex | Web CSS Variable | Tailwind | SwiftUI |
|---|---|---|---|---|
| Background | `#0A0E1A` | `--background: 222.2 84% 4.9%` | `bg-background` | `Color.amachBg` |
| Surface | `#111827` | `--card: 222.2 84% 4.9%` | `bg-card` | `Color.amachSurface` |
| Surface Elevated | `#1A2234` | — | `bg-muted` | `Color.amachSurfaceElevated` |
| Primary | `#10B981` | `--primary: 142.1 70.6% 45.3%` | `emerald-500` | `Color.amachPrimary` |
| Primary Bright | `#34D399` | (dark mode accent) | `emerald-400` | `Color.amachPrimaryBright` |
| Accent | `#F59E0B` | `--accent` | `amber-500` | `Color.amachAccent` |
| Text Primary | `#F9FAFB` | `--foreground: 210 40% 98%` | `text-foreground` | `Color.amachTextPrimary` |
| Text Secondary | `#9CA3AF` | `--muted-foreground` | `text-muted-foreground` | `Color.amachTextSecondary` |
| Border | `amachPrimary @15%` | `--border: 217.2 32.6% 17.5%` | `border-border` | `Color.amachPrimary.opacity(0.15)` |
| Destructive | `#F87171` | `--destructive: 0 62.8% 30.6%` | `red-400` | `Color.amachDestructive` |

### Tier Colors

| Tier | Background | Text | SwiftUI |
|---|---|---|---|
| Gold | `amachAccent @15%` | `#F59E0B` | `Color.amachGold` |
| Silver | `amachSilver @15%` | `#94A3B8` | `Color.amachSilver` |
| Bronze | `amachBronze @15%` | `#CD7F32` | `Color.amachBronze` |
| None | `amachSurface` | `amachTextSecondary` | — |

### Status Colors

| Status | Color | Usage |
|---|---|---|
| Success | `#34D399` (`amachPrimaryBright`) | Synced, authorized, connected |
| Warning | `#F59E0B` (`amachAccent`) | Pending, needs attention |
| Error | `#F87171` (`amachDestructive`) | Failed, invalid |
| Info | `#818CF8` | Sleep metric, informational |

---

## Typography

### Font Stack

- **Web**: `Inter, system-ui, sans-serif` (Google Fonts)
- **iOS**: SF Pro (system default) — no import needed

### Scale

| Name | Web (Tailwind) | iOS (SwiftUI) | Usage |
|---|---|---|---|
| Brand Label | `text-xs tracking-widest` | `.caption2 .tracking(2.5)` | "AMACH HEALTH" eyebrow |
| H1 | `text-2xl font-black` | `.title2 .fontWeight(.bold)` | Page titles, greetings |
| H2 | `text-xl` | `.title3` | Section headers |
| H3 | `text-lg` | `.headline` | Card titles |
| Body | `text-base` | `.subheadline` | Main content |
| Caption | `text-sm` | `.caption` | Secondary info |
| Tiny | `text-xs` | `.caption2` | Timestamps, badges |
| Metric Value | `text-4xl font-black` | `.system(size:22, weight:.bold, design:.rounded)` | Dashboard numbers |

---

## Spacing

4pt base unit (same as web's Tailwind):

| Token | Value | Tailwind | SwiftUI |
|---|---|---|---|
| xs | 4pt | `p-1` | `4` |
| sm | 8pt | `p-2` | `8` |
| md | 14-16pt | `p-4` | `14–16` |
| lg | 20-24pt | `p-6` | `20–24` |
| xl | 32pt | `p-8` | `32` |

---

## Border Radius

iOS uses `clipShape(RoundedRectangle(cornerRadius:))` — does **not** use `.cornerRadius()` deprecated API.

| Token | Value | Web CSS var | Tailwind | SwiftUI |
|---|---|---|---|---|
| sm | 8pt | `--radius: 0.5rem` | `rounded-lg` | `cornerRadius(8)` |
| md | 14pt | — | `rounded-xl` | `cornerRadius(14)` |
| lg | 16pt | — | `rounded-2xl` | `cornerRadius(16)` |
| pill | 99pt | — | `rounded-full` | `Capsule()` |

---

## Components

### Buttons

**Primary CTA**
- Background: `amachPrimary` (`#10B981`)
- Text: White
- Radius: md (14pt)
- Shadow: `amachPrimary @ 0.4 opacity, radius 12`
- Disabled: `amachSurface` background, `amachTextSecondary` text

**Secondary / Pill**
- Background: `amachPrimary @ 0.15`
- Border: `amachPrimary @ 0.3`
- Text: `amachPrimaryBright`
- Shape: `Capsule()`

### Cards

```swift
// Standard card modifier
.background(Color.amachSurface)
.clipShape(RoundedRectangle(cornerRadius: 16))
.overlay(
    RoundedRectangle(cornerRadius: 16)
        .stroke(Color.amachPrimary.opacity(0.12), lineWidth: 1)
)
```

### Tier Badges

```swift
// TierBadge(tier: "GOLD")
// Small pill with colored bg + border
.font(.caption2).fontWeight(.bold).tracking(0.5)
.padding(.horizontal, 8).padding(.vertical, 3)
.clipShape(RoundedRectangle(cornerRadius: 5))
```

### Connection Status Row

Icon circle (40×40) + title/subtitle VStack + trailing status pill or CTA button.

### Metric Cards (Dashboard)

- Icon in colored rounded-rect (28×28, `color.opacity(0.12)` bg)
- Large rounded-number value + small unit label
- Metric label below
- Two-column LazyVGrid layout

### Trend Charts (Swift Charts)

- `LineMark` with `catmullRom` interpolation
- `AreaMark` with `LinearGradient` fill (color @ 0.18 → clear)
- Chart axes: minimal grid lines at `amachPrimary.opacity(0.06)`
- Height: 90pt per chart

### Chat Bubbles

- User: `amachPrimary` background, white text, emerald glow shadow, right-aligned
- Assistant: `amachSurface` bg, `amachPrimary @ 0.12` border, left-aligned with sparkle avatar
- Typing indicator: 3-dot bounce animation

---

## Layout Patterns

### Dashboard Screen

```
┌─────────────────────────────────┐
│ AMACH HEALTH (eyebrow)          │
│ Good morning         [● Score]  │
│ Synced 2h ago         [ring]    │
├─────────────────────────────────┤
│ TODAY                           │
│ ┌────┐ ┌────┐                   │
│ │Steps│ │Cal │  ← 2-col grid   │
│ └────┘ └────┘                   │
│ ┌────┐ ┌────┐                   │
│ │ HR  │ │Sleep│                  │
│ └────┘ └────┘                   │
│ ┌────┐ ┌────┐                   │
│ │ HRV │ │Exer│                  │
│ └────┘ └────┘                   │
├─────────────────────────────────┤
│ TRENDS     [7D] [30D] [3M]      │
│ ┌ Steps line chart ────────────┐│
│ ┌ Heart Rate chart ────────────┐│
│ ┌ Sleep chart ─────────────────┐│
│ ┌ HRV chart ───────────────────┐│
└─────────────────────────────────┘
```

### Chat Screen

```
┌─────────────────────────────────┐
│ ✦ Cosaint    [history] [new]    │
├─────────────────────────────────┤
│                                 │
│  [✦] How are my steps?          │ ← assistant bubble
│                   8,432 today ✓ │ ← user bubble
│  [✦] That's a great pace…       │
│                                 │
├─────────────────────────────────┤
│ [Ask Cosaint…________] [↑]      │
└─────────────────────────────────┘
```

### Sync Screen

```
┌─────────────────────────────────┐
│ ● HealthKit  [Connected]        │
│ ● Wallet     [0x1234…abcd]      │
├─────────────────────────────────┤
│ ✓ Sync Successful   2h ago      │
│   [GOLD]  87% complete          │
│   32 Metrics   365 Days         │
├─────────────────────────────────┤
│ Sync from [Feb 19, 2025 ›]      │
│ [    Sync Health Data     ]     │
│ [⟁ View Stored Data           ›]│
└─────────────────────────────────┘
```

---

## Icons

SF Symbols on iOS, Lucide on web:

| Concept | SF Symbol | Lucide |
|---|---|---|
| Health | `heart.fill` | `Heart` |
| Wallet | `wallet.pass.fill` | `Wallet` |
| Sync | `arrow.triangle.2.circlepath` | `RefreshCw` |
| Storage | `externaldrive.fill` | `HardDrive` |
| AI Agent | `sparkles` | `Sparkles` |
| Dashboard | `chart.xyaxis.line` | `BarChart2` |
| Success | `checkmark.circle.fill` | `CheckCircle` |
| Error | `xmark.circle.fill` | `XCircle` |
| Settings | `gearshape.fill` | `Settings` |
| On-chain | `checkmark.seal.fill` | `Shield` |
| Sleep | `moon.fill` | `Moon` |
| HRV | `waveform.path.ecg` | `Activity` |

---

## Data Flow: iOS ↔ Web App

```
iPhone (HealthKit)
    ↓ DashboardService   → live read, no upload
    ↓ HealthDataSyncService → full sync
         ↓
    AmachAPIClient
         ↓
    POST /api/storj (store/list/retrieve)
    POST /api/ai/chat (Cosaint)
    POST /api/attestations
         ↓
    Amach Backend (app.amach.health)
         ↓
    Storj (encrypted)  +  ZKsync (attestation)  +  Venice AI (chat)
         ↑
    Web App (Amach-Website) reads same Storj data
```

**Chat storage:**
- Local: `amach_chat_sessions.json` in Documents directory
- Remote: `POST /api/storj` with `dataType: "chat-session"` every 10 messages or on new session

---

## Accessibility

- Minimum touch target: 44×44pt
- Color contrast: WCAG AA (4.5:1 text minimum)
- Dynamic Type: Use relative SwiftUI font styles (`.headline`, `.body`, etc.)
- VoiceOver: All interactive elements require accessible labels

## Animation

- Duration: 200–300ms micro-interactions
- Spring: `.spring(response: 0.25–0.35)` for UI transitions
- Easing: `.easeOut` for entrances, `.easeIn` for exits
- Chart interpolation: `.catmullRom` for smooth curves
- Glow pulse: `amachPrimary.opacity(0.3–0.5)` shadow, radius 8–12pt
- Respect reduced motion: check `UIAccessibility.isReduceMotionEnabled`
