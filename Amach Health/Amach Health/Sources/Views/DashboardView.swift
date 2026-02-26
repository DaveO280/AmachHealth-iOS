// DashboardView.swift
// AmachHealth
//
// Tab 1: Health metrics overview (home screen).
// The most important screen in the app — shown every time Amach opens.
//
// Layout (top → bottom):
//   Header         brand mark + greeting + sync status + score ring
//   LumaInsight    proactive AI insight card (if data available)
//   Today Metrics  6-card 2-column grid — tappable, each navigates to detail
//   Empty State    when no data is synced (first-time user)
//
// Design principle: "Clarity Over Cleverness."
// Every element must earn its space. No decoration for decoration's sake.

import SwiftUI
import Charts

struct DashboardView: View {
    @StateObject private var dashboard = DashboardService.shared
    @EnvironmentObject private var syncService: HealthDataSyncService
    @EnvironmentObject private var healthKit: HealthKitService
    @ObservedObject private var lumaContext = LumaContextService.shared

    @State private var showLuma = false
    @State private var selectedMetric: MetricInfo? = nil

    private var hasData: Bool {
        dashboard.today.steps > 0
            || dashboard.today.heartRateAvg > 0
            || dashboard.today.hrv > 0
            || dashboard.today.sleepHours > 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.amachBg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: AmachSpacing.lg) {
                        headerSection

                        if dashboard.isLoading && !hasData {
                            skeletonSection
                        } else if !hasData && !healthKit.isAuthorized {
                            emptyState
                        } else {
                            if hasData {
                                lumaInsightSection
                            }
                            todaySection
                        }

                        // Extra padding for Luma FAB
                        Spacer().frame(height: AmachSpacing.xxxl + AmachSpacing.md)
                    }
                    .padding(.horizontal, AmachSpacing.md)
                    .padding(.top, AmachSpacing.sm)
                    .padding(.bottom, AmachSpacing.md)
                }
                .refreshable {
                    AmachHaptics.pullRefresh()
                    await dashboard.load(force: true)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(item: $selectedMetric) { metric in
                MetricDetailView(metric: metric)
            }
        }
        .task {
            await dashboard.load()
            lumaContext.update(screen: "Dashboard")
        }
        .sheet(isPresented: $showLuma) {
            LumaSheetView()
                .environmentObject(healthKit)
        }
    }

    // ============================================================
    // MARK: - Header
    // ============================================================

    private var headerSection: some View {
        HStack(alignment: .center, spacing: AmachSpacing.md) {
            VStack(alignment: .leading, spacing: 5) {
                AmachBrandMark(layout: .compact)

                Text(greeting)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.amachTextPrimary)

                syncStatusLine
            }

            Spacer()

            // Health score ring
            if let result = syncService.lastSyncResult, let score = result.score {
                healthScoreRing(score: score, tier: result.tier)
            } else {
                emptyScoreRing
            }
        }
        .padding(.top, AmachSpacing.xs)
    }

    private var syncStatusLine: some View {
        Group {
            if let date = syncService.lastSyncDate {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.amachPrimaryBright)
                        .frame(width: 5, height: 5)
                    Text("Synced \(timeSince(date))")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            } else if healthKit.isAuthorized {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.amachWarning)
                        .frame(width: 5, height: 5)
                    Text("Not yet synced to vault")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            } else {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.amachTextSecondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text("Connect Apple Health")
                        .font(AmachType.tiny)
                        .foregroundStyle(Color.amachTextSecondary)
                }
            }
        }
        .accessibilityLabel(syncService.lastSyncDate != nil ? "Last synced \(timeSince(syncService.lastSyncDate!))" : "Not synced")
    }

    private func healthScoreRing(score: Int, tier: String?) -> some View {
        ZStack {
            // Background track
            Circle()
                .stroke(Color.amachPrimary.opacity(0.12), lineWidth: 5)
                .frame(width: 64, height: 64)

            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(
                    Color.amachPrimaryBright,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 64, height: 64)
                .shadow(color: Color.amachPrimary.opacity(0.4), radius: 6)
                .animation(AmachAnimation.chartDraw, value: score)

            // Center content
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.amachTextPrimary)
                if let tier, tier != "NONE" {
                    Text(String(tier.prefix(1)))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(tierColor(tier))
                }
            }
        }
        .accessibilityLabel("Health data score: \(score) out of 100\(tier.map { ", \($0) tier" } ?? "")")
    }

    private var emptyScoreRing: some View {
        ZStack {
            Circle()
                .stroke(Color.amachPrimary.opacity(0.1), lineWidth: 5)
                .frame(width: 64, height: 64)
            Image(systemName: "heart.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.amachPrimary.opacity(0.3))
        }
    }

    // ============================================================
    // MARK: - Luma Insight Card
    // ============================================================

    private var lumaInsightSection: some View {
        LumaInsightCard(
            insight: dashboardInsight,
            onAsk: {
                AmachHaptics.cardTap()
                lumaContext.update(screen: "Dashboard")
                showLuma = true
            }
        )
    }

    private var dashboardInsight: String {
        let steps = dashboard.today.steps
        let hrv = dashboard.today.hrv
        let sleep = dashboard.today.sleepHours
        let hr = dashboard.today.heartRateAvg

        if hrv > 60 && sleep >= 7 {
            return "Your body looks well-recovered. HRV is strong and sleep was solid. A good day for a workout or focused work."
        } else if hrv < 30 {
            return "Your HRV is lower than usual — a sign your body may need recovery. Consider lighter activity today and check your sleep quality."
        } else if sleep < 6 {
            return "Short sleep night detected. Cognitive performance can take a 20–30% hit after under 6 hours. Hydrate and consider your workload today."
        } else if steps > 10000 {
            return "You hit 10k+ steps already — consistency here is one of the highest-return longevity habits. Keep it up."
        } else if hr > 90 && hrv > 0 {
            return "Your resting heart rate is elevated. This can reflect stress, dehydration, or early illness. Worth noting if it continues tomorrow."
        }
        return "I'm tracking your activity, heart rate, and sleep to find patterns. Tap to ask me what I'm seeing or what to focus on today."
    }

    // ============================================================
    // MARK: - Today Section (Metric Grid)
    // ============================================================

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            HStack {
                sectionLabel("TODAY")
                Spacer()
                if dashboard.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Color.amachPrimaryBright)
                }
            }

            LazyVGrid(
                columns: AmachLayout.twoColumnGrid,
                spacing: AmachLayout.cardMinHeight <= 100 ? AmachSpacing.cardGap : AmachSpacing.cardGap
            ) {
                tappableMetricCard(.steps(dashboard.today.steps))
                tappableMetricCard(.calories(dashboard.today.activeCalories))
                tappableMetricCard(.heartRate(dashboard.today.heartRateAvg))
                tappableMetricCard(.sleep(dashboard.today.sleepHours))
                tappableMetricCard(.hrv(dashboard.today.hrv))
                tappableMetricCard(.exercise(dashboard.today.exerciseMinutes))
            }
        }
    }

    @ViewBuilder
    private func tappableMetricCard(_ metric: MetricInfo) -> some View {
        Button {
            AmachHaptics.cardTap()
            selectedMetric = metric
        } label: {
            EnhancedMetricCard(metric: metric)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(metric.label): \(metric.value) \(metric.unit). Status: \(statusLabel(metric.status)). Tap for details.")
    }

    // ============================================================
    // MARK: - Skeleton Loading State
    // ============================================================

    private var skeletonSection: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            sectionLabel("TODAY")

            LazyVGrid(columns: AmachLayout.twoColumnGrid, spacing: AmachSpacing.cardGap) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonMetricCard()
                }
            }
        }
    }

    // ============================================================
    // MARK: - Empty State (New User)
    // ============================================================

    private var emptyState: some View {
        VStack(spacing: AmachSpacing.xl) {
            Spacer().frame(height: AmachSpacing.lg)

            // Illustration — Luma + brand mark
            ZStack {
                Circle()
                    .fill(Color.Amach.AI.base.opacity(0.06))
                    .frame(width: 130, height: 130)
                Circle()
                    .fill(Color.Amach.AI.base.opacity(0.03))
                    .frame(width: 160, height: 160)
                Image(systemName: "sparkles")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.Amach.AI.p400)
                    .shadow(color: Color.Amach.AI.base.opacity(0.3), radius: 20)
            }

            VStack(spacing: AmachSpacing.sm) {
                Text("Your health story\nstarts here.")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.amachTextPrimary)
                    .multilineTextAlignment(.center)

                Text("Connect your data and Luma will start finding the signals that matter.")
                    .font(AmachType.body)
                    .foregroundStyle(Color.amachTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, AmachSpacing.md)
            }

            // Luma's intro message
            VStack(alignment: .leading, spacing: AmachSpacing.sm) {
                HStack(spacing: AmachSpacing.sm) {
                    Circle()
                        .fill(Color.Amach.AI.base.opacity(0.18))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "sparkles")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.Amach.AI.p400)
                        )
                    Text("Luma")
                        .font(AmachType.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Amach.AI.p400)
                }

                Text("Hi! Once you connect your health data, I can start finding patterns and insights just for you. Want to start with Apple Health?")
                    .font(AmachType.caption)
                    .foregroundStyle(Color.amachTextPrimary)
                    .lineSpacing(4)
                    .padding(.horizontal, AmachSpacing.md)
                    .padding(.vertical, AmachSpacing.sm + 2)
                    .background(Color.Amach.AI.dark.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: AmachRadius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: AmachRadius.lg)
                            .stroke(Color.Amach.AI.base.opacity(0.2), lineWidth: 1)
                    )
            }
            .padding(.horizontal, AmachSpacing.md)

            // CTAs
            VStack(spacing: AmachSpacing.sm) {
                Button {
                    Task { try? await healthKit.requestAuthorization() }
                } label: {
                    HStack(spacing: AmachSpacing.sm) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 15))
                        Text("Connect Apple Health")
                    }
                }
                .amachPrimaryButtonStyle()
                .padding(.horizontal, AmachSpacing.xl)

                Button {
                    AmachHaptics.cardTap()
                    showLuma = true
                } label: {
                    HStack(spacing: AmachSpacing.sm) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                        Text("Talk to Luma")
                    }
                }
                .amachSecondaryButtonStyle()
                .padding(.horizontal, AmachSpacing.xl)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // ============================================================
    // MARK: - Helpers
    // ============================================================

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(AmachType.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(Color.amachTextSecondary)
            .tracking(1.5)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<5:  return "Up late"
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default:     return "Good evening"
        }
    }

    private func timeSince(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 60   { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        if secs < 86400 { return "\(Int(secs / 3600))h ago" }
        return "\(Int(secs / 86400))d ago"
    }

    private func tierColor(_ tier: String) -> Color {
        switch tier.uppercased() {
        case "GOLD":   return Color.amachAccent
        case "SILVER": return Color.amachSilver
        case "BRONZE": return Color.amachBronze
        default:       return Color.amachTextSecondary
        }
    }

    private func statusLabel(_ status: HealthStatusPill.Status) -> String {
        switch status {
        case .optimal:    return "Optimal"
        case .borderline: return "Borderline"
        case .critical:   return "Needs attention"
        case .noData:     return "No data"
        }
    }
}


// ============================================================
// MARK: - ENHANCED METRIC CARD
// ============================================================
// Replaces the original MetricCard.
// Adds: status pill, press state scale effect, proper padding.

struct EnhancedMetricCard: View {
    let metric: MetricInfo
    @State private var isPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            // Icon
            Image(systemName: metric.icon)
                .font(.system(size: 14))
                .foregroundStyle(metric.color)
                .frame(width: 30, height: 30)
                .background(metric.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AmachRadius.xs + 2))

            Spacer(minLength: 2)

            // Value + unit
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text(metric.value.isEmpty || metric.value == "0" ? "—" : metric.value)
                        .font(AmachType.dataValue(size: 24))
                        .foregroundStyle(Color.amachTextPrimary)
                        .contentTransition(.numericText())

                    if !metric.unit.isEmpty && metric.rawValue > 0 {
                        Text(metric.unit)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.amachTextSecondary)
                    }
                }

                Text(metric.label)
                    .font(AmachType.tiny)
                    .foregroundStyle(Color.amachTextSecondary)
            }

            // Status pill
            HealthStatusPill(status: metric.rawValue > 0 ? metric.status : .noData)
        }
        .padding(AmachSpacing.md)
        .frame(maxWidth: .infinity, minHeight: AmachLayout.cardMinHeight, alignment: .leading)
        .background(Color.amachSurface)
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AmachRadius.card)
                .stroke(metric.color.opacity(0.12), lineWidth: 1)
        )
        .shadow(
            color: AmachElevation.Level1.shadowColor,
            radius: AmachElevation.Level1.shadowRadius,
            x: AmachElevation.Level1.shadowX,
            y: AmachElevation.Level1.shadowY
        )
        .scaleEffect(isPressed ? AmachAnimation.cardPressScale : 1.0)
        .animation(AmachAnimation.ifMotion(AmachAnimation.spring), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}


// ============================================================
// MARK: - SKELETON METRIC CARD
// ============================================================

struct SkeletonMetricCard: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: AmachSpacing.sm) {
            RoundedRectangle(cornerRadius: AmachRadius.xs + 2)
                .fill(Color.amachSurface)
                .frame(width: 30, height: 30)
            Spacer(minLength: 2)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.amachSurface)
                .frame(width: 60, height: 22)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.amachSurface)
                .frame(width: 40, height: 12)
            RoundedRectangle(cornerRadius: AmachRadius.pill)
                .fill(Color.amachSurface)
                .frame(width: 55, height: 18)
        }
        .padding(AmachSpacing.md)
        .frame(maxWidth: .infinity, minHeight: AmachLayout.cardMinHeight, alignment: .leading)
        .background(Color.amachSurface.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
        .overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.04), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.6)
                .offset(x: phase * (geo.size.width + geo.size.width * 0.6) - geo.size.width * 0.6)
            }
            .clipShape(RoundedRectangle(cornerRadius: AmachRadius.card))
        )
        .onAppear {
            withAnimation(
                .linear(duration: AmachAnimation.durationShimmer)
                .repeatForever(autoreverses: false)
            ) {
                phase = 1
            }
        }
    }
}


// ============================================================
// MARK: - SHIMMER EXTENSION (keep for compatibility)
// ============================================================

extension View {
    func shimmering() -> some View {
        self.opacity(0.6)
    }
}


// ============================================================
// MARK: - PREVIEW
// ============================================================

#Preview("Dashboard — With Data") {
    DashboardView()
        .environmentObject(HealthDataSyncService.shared)
        .environmentObject(HealthKitService.shared)
        .environmentObject(LumaContextService.shared)
        .preferredColorScheme(.dark)
}

#Preview("Dashboard — Empty State") {
    DashboardView()
        .environmentObject(HealthDataSyncService.shared)
        .environmentObject(HealthKitService.shared)
        .environmentObject(LumaContextService.shared)
        .preferredColorScheme(.dark)
}
