# Amach Health Design System

Shared design tokens and guidelines for web and iOS apps.

## Colors

### Brand Colors

| Name           | Hex       | Tailwind      | SwiftUI                             |
| -------------- | --------- | ------------- | ----------------------------------- |
| Primary        | `#006B4F` | `emerald-700` | `Color(hex: "006B4F")`              |
| Primary Dark   | `#005540` | `emerald-800` | `Color(hex: "005540")`              |
| Primary Light  | `#E8F5F0` | `emerald-50`  | `Color(hex: "E8F5F0")`              |
| Accent         | `#F59E0B` | `amber-500`   | `Color.orange`                      |
| Background     | `#FFFFFF` | `white`       | `Color(.systemBackground)`          |
| Surface        | `#F9FAFB` | `gray-50`     | `Color(.secondarySystemBackground)` |
| Text Primary   | `#111827` | `gray-900`    | `Color(.label)`                     |
| Text Secondary | `#6B7280` | `gray-500`    | `Color(.secondaryLabel)`            |

### Tier Colors

| Tier   | Background | Text      | Border    |
| ------ | ---------- | --------- | --------- |
| Gold   | `#FEF3C7`  | `#B45309` | `#FCD34D` |
| Silver | `#F1F5F9`  | `#475569` | `#CBD5E1` |
| Bronze | `#FEF3C7`  | `#B45309` | `#FBBF24` |
| None   | `#F3F4F6`  | `#6B7280` | `#D1D5DB` |

### Status Colors

| Status  | Color     | Usage                    |
| ------- | --------- | ------------------------ |
| Success | `#10B981` | Completed syncs, valid   |
| Warning | `#F59E0B` | Pending, needs attention |
| Error   | `#EF4444` | Failed, invalid          |
| Info    | `#3B82F6` | Informational            |

## Typography

### Font Stack

- **Web**: `Inter, system-ui, sans-serif`
- **iOS**: SF Pro (system default)

### Scale

| Name    | Web (Tailwind) | iOS (SwiftUI) | Usage              |
| ------- | -------------- | ------------- | ------------------ |
| H1      | `text-2xl`     | `.title`      | Page titles        |
| H2      | `text-xl`      | `.title2`     | Section headers    |
| H3      | `text-lg`      | `.title3`     | Card titles        |
| Body    | `text-base`    | `.body`       | Main content       |
| Caption | `text-sm`      | `.caption`    | Secondary info     |
| Tiny    | `text-xs`      | `.caption2`   | Timestamps, badges |

## Spacing

Use 4px base unit:

| Token | Value | Tailwind | SwiftUI |
| ----- | ----- | -------- | ------- |
| xs    | 4px   | `p-1`    | `4`     |
| sm    | 8px   | `p-2`    | `8`     |
| md    | 16px  | `p-4`    | `16`    |
| lg    | 24px  | `p-6`    | `24`    |
| xl    | 32px  | `p-8`    | `32`    |

## Border Radius

| Token | Value  | Tailwind       | SwiftUI                |
| ----- | ------ | -------------- | ---------------------- |
| sm    | 4px    | `rounded`      | `.cornerRadius(4)`     |
| md    | 8px    | `rounded-lg`   | `.cornerRadius(8)`     |
| lg    | 12px   | `rounded-xl`   | `.cornerRadius(12)`    |
| full  | 9999px | `rounded-full` | `.clipShape(Circle())` |

## Components

### Buttons

**Primary Button**

- Background: Primary (`#006B4F`)
- Text: White
- Border radius: md (8px)
- Padding: 12px vertical, 16px horizontal

**Secondary Button**

- Background: Transparent
- Border: 1px Primary
- Text: Primary
- Border radius: md (8px)

### Cards

- Background: White
- Border: 1px `gray-200` (`#E5E7EB`)
- Border radius: lg (12px)
- Shadow: `shadow-sm` / subtle drop shadow
- Padding: lg (24px)

### Tier Badges

Small pill-shaped badges:

- Font: Tiny, semibold
- Padding: 4px horizontal, 2px vertical
- Border radius: sm (4px)
- Colors: See tier colors above

### Progress Indicators

- Track: `gray-200`
- Fill: Primary (`#006B4F`) or tier color
- Height: 8px
- Border radius: full

## Layout Patterns

### Health Sync Screen

```
┌─────────────────────────────────┐
│ Navigation Bar                  │
├─────────────────────────────────┤
│ ┌─────────────────────────────┐ │
│ │ HealthKit Status Card       │ │
│ │ [Icon] [Status] [Action]    │ │
│ └─────────────────────────────┘ │
│ ┌─────────────────────────────┐ │
│ │ Wallet Status Card          │ │
│ │ [Icon] [Address] [Action]   │ │
│ └─────────────────────────────┘ │
│                                 │
│ ┌─────────────────────────────┐ │
│ │ Last Sync Result            │ │
│ │ [Tier Badge] [Score]        │ │
│ │ [Metrics] [Days Covered]    │ │
│ └─────────────────────────────┘ │
│                                 │
│ ┌─────────────────────────────┐ │
│ │ [    Sync Health Data    ]  │ │
│ └─────────────────────────────┘ │
└─────────────────────────────────┘
```

### Storage List Item

```
┌─────────────────────────────────┐
│ Apple Health Export    [GOLD]   │
│ 2024-02-17 to 2025-02-17        │
│ 56 metrics          2 hours ago │
└─────────────────────────────────┘
```

## Icons

Use SF Symbols on iOS, Lucide icons on web:

| Concept  | SF Symbol                     | Lucide        |
| -------- | ----------------------------- | ------------- |
| Health   | `heart.fill`                  | `Heart`       |
| Wallet   | `wallet.pass.fill`            | `Wallet`      |
| Sync     | `arrow.triangle.2.circlepath` | `RefreshCw`   |
| Storage  | `externaldrive.fill`          | `HardDrive`   |
| Success  | `checkmark.circle.fill`       | `CheckCircle` |
| Error    | `xmark.circle.fill`           | `XCircle`     |
| Upload   | `arrow.up.circle.fill`        | `Upload`      |
| Settings | `gearshape.fill`              | `Settings`    |

## Accessibility

- Minimum touch target: 44x44pt (iOS), 44x44px (web)
- Color contrast: WCAG AA minimum (4.5:1 for text)
- Support Dynamic Type (iOS) and browser zoom (web)
- Provide labels for all interactive elements

## Animation

- Duration: 200-300ms for micro-interactions
- Easing: ease-out for entrances, ease-in for exits
- Reduce motion: Respect user preferences
