// LumaProactiveService.swift
// AmachHealth
//
// Orchestrates Luma's proactive health intelligence loop:
//
//   1. DETECT   — AnomalyDetector evaluates latest readings on-device (no network)
//   2. STAGE    — Anomalies above threshold become HealthEvents + PendingInsights
//   3. NOTIFY   — Templated local notification fires (no Venice call yet)
//   4. DELIVER  — On app foreground, Venice generates the full Luma message
//                 (streaming, so it feels alive not pre-canned)
//   5. REMEMBER — HealthMemoryStore records event; ChatService links session
//
// The Venice call happens in step 4, not step 3.
// This keeps background tasks network-free and makes the streaming response
// feel like Luma is composing in real-time when the user opens the notification.

import Foundation
import UserNotifications

@MainActor
final class LumaProactiveService: ObservableObject {
    static let shared = LumaProactiveService()

    // Published so views can react when a pending insight is ready to deliver
    @Published var pendingDelivery: (event: HealthEvent, insight: PendingProactiveInsight)?

    private let store: HealthMemoryStore = .shared
    private let detector: AnomalyDetector = AnomalyDetector()
    private let api: AmachAPIClient = .shared

    // Whether the user has opted in to proactive insights
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "luma.proactiveEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "luma.proactiveEnabled") }
    }

    private init() {}

    // MARK: - Opt-in

    /// Request notification permission and enable proactive mode.
    /// Call this after the user confirms the opt-in sheet.
    func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
        if granted {
            isEnabled = true
        }
        return granted
    }

    func disable() {
        isEnabled = false
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        store.clearPendingInsights()
    }

    // MARK: - Step 1+2: Detect and Stage (background-safe, no network)

    /// Evaluate new daily summaries. Records any significant anomalies and
    /// stages pending insights for delivery. Network-free.
    ///
    /// Called by HealthDataSyncService after each sync, and by
    /// BackgroundAnomalyTask on background HealthKit observer fires.
    func evaluateAndStage(dailySummaries: [String: DailySummary]) {
        guard isEnabled else { return }

        // Update baselines with new readings first
        store.updateBaselines(from: dailySummaries)

        // Check whether prior anomalies have resolved
        detector.checkResolutions(from: dailySummaries)

        // Detect new anomalies
        let signals = detector.evaluate(dailySummaries: dailySummaries)
        guard let topSignal = signals.first else { return }

        // Skip if we already have an active event for this metric —
        // prevents re-notifying for the same ongoing anomaly
        guard !store.hasActiveAnomaly(for: topSignal.metricType) else { return }

        // Skip if Luma recently discussed this metric in chat
        guard !ChatService.shared.hasRecentDiscussion(about: topSignal.metricType) else { return }

        let profile = store.profile(for: topSignal.metricType)
        guard let event = topSignal.toHealthEvent(using: profile) else { return }
        store.record(event)
        store.markSurfaced(event.id)

        let notifText = buildNotificationText(for: topSignal)
        let pending = PendingProactiveInsight(
            healthEventId: event.id,
            notificationText: notifText
        )
        store.stagePendingInsight(pending)

        // Step 3: fire local notification
        scheduleNotification(pending)
    }

    // MARK: - Step 3: Notify (templated, on-device)

    private func scheduleNotification(_ insight: PendingProactiveInsight) {
        let content = UNMutableNotificationContent()
        content.title = "Luma noticed something"
        content.body = insight.notificationText
        content.sound = .default
        content.userInfo = ["insightId": insight.id.uuidString]

        // Deliver after a short delay so the user isn't mid-sync
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 30, repeats: false)
        let request = UNNotificationRequest(
            identifier: insight.id.uuidString,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func buildNotificationText(for signal: AnomalySignal) -> String {
        let label = humanReadableLabel(for: signal.metricType)
        let pct = abs(Int(((signal.currentValue - signal.baseline.mean) / signal.baseline.mean) * 100))
        switch signal.direction {
        case .declining:
            return "Your \(label) has dropped \(pct)% below your usual range for \(signal.consecutiveDaysOutside) days."
        case .spiking:
            return "Your \(label) has been \(pct)% above your usual range for \(signal.consecutiveDaysOutside) days."
        case .unusualPattern:
            return "Luma noticed an unusual pattern in your \(label)."
        }
    }

    // MARK: - Step 4: Deliver (called on app foreground, returns streaming context)

    /// Call this when the app foregrounds (from AppState or scene phase handler).
    /// If a pending insight is waiting, loads the HealthEvent and publishes it
    /// so ChatView can open with the proactive message and begin streaming.
    func checkAndDeliverPendingInsight() {
        guard isEnabled else { return }
        guard let pending = store.consumeNextPendingInsight() else { return }
        guard let event = store.events.first(where: { $0.id == pending.healthEventId }) else { return }
        pendingDelivery = (event: event, insight: pending)
    }

    /// Build the Venice context for a proactive insight delivery.
    /// This is what gets passed to ChatService.sendStreaming() as the opening message.
    func buildVeniceContext(for event: HealthEvent) -> ProactiveInsightContext {
        let priorResolved = store.recentEvents(for: event.metricType, limit: 4)
            .filter { $0.outcome != nil && $0.id != event.id }
            .prefix(3)

        let priorPayloads = priorResolved.map { prior in
            ProactiveInsightContext.PriorEventPayload(
                summary: prior.narrativeSummary,
                daysSince: Calendar.current.dateComponents(
                    [.day], from: prior.detectedAt, to: .now
                ).day ?? 0
            )
        }

        return ProactiveInsightContext(
            screen: "proactive_insight",
            triggerType: "anomaly_detected",
            anomaly: ProactiveInsightContext.AnomalyPayload(
                metricType: event.metricType,
                baselineValue: event.baselineValue,
                currentValue: event.peakDeviation,
                deviationPct: event.deviationPct,
                durationDays: event.durationDays,
                direction: event.direction.rawValue
            ),
            priorEvents: Array(priorPayloads),
            relevantSessionSummaries: store.priorNarratives(for: event.metricType)
        )
    }

    /// The opening message sent to Venice when delivering a proactive insight.
    /// This is a structured prompt — Venice/Luma will respond as the companion opening.
    func buildOpeningMessage(for event: HealthEvent) -> String {
        let label = humanReadableLabel(for: event.metricType)
        let sign = event.deviationPct >= 0 ? "+" : ""
        let pctStr = "\(sign)\(String(format: "%.0f", event.deviationPct))%"
        return "proactive_insight: \(label) \(event.direction.displayLabel) \(pctStr) from baseline for \(event.durationDays) days"
    }

    // MARK: - Step 5: Link session after chat begins

    /// Call this once the ChatService creates a session for the proactive insight.
    /// Links the session back to the HealthEvent for future cross-session memory.
    func linkSession(_ sessionId: UUID, to eventId: UUID) {
        store.linkSession(sessionId, to: eventId)
    }

    // MARK: - Helpers

    private func humanReadableLabel(for metricType: String) -> String {
        switch metricType {
        case "heartRateVariabilitySDNN": return "HRV"
        case "restingHeartRate":         return "resting heart rate"
        case "sleepDuration":            return "sleep duration"
        case "sleepEfficiency":          return "sleep quality"
        case "stepCount":                return "daily steps"
        case "activeEnergyBurned":       return "active energy"
        case "respiratoryRate":          return "respiratory rate"
        case "oxygenSaturation":         return "blood oxygen"
        default:                         return metricType
        }
    }
}
