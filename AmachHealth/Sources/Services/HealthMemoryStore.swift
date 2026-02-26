// HealthMemoryStore.swift
// AmachHealth
//
// Persistent store for Luma's longitudinal health memory.
//
// Responsibilities:
//   - Record and resolve HealthEvents (anomaly lifecycle)
//   - Maintain PersonalBaselines per metric (updated from daily readings)
//   - Stage and clear PendingProactiveInsights (background → foreground handoff)
//   - Provide narrative summaries for Venice context injection
//
// Storage: two local JSON files in Documents —
//   amach_health_events.json     — [HealthEvent]
//   amach_baselines.json         — [String: PersonalBaseline]
//   amach_pending_insights.json  — [PendingProactiveInsight]
//
// These are intentionally separate from chat session storage so they
// persist across session resets and are queryable independently.

import Combine
import Foundation

@MainActor
final class HealthMemoryStore: ObservableObject {
    static let shared = HealthMemoryStore()

    @Published private(set) var events: [HealthEvent] = []
    @Published private(set) var pendingInsights: [PendingProactiveInsight] = []

    private var baselines: [String: PersonalBaseline] = [:]

    private let eventsURL: URL
    private let baselinesURL: URL
    private let pendingURL: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        eventsURL  = docs.appendingPathComponent("amach_health_events.json")
        baselinesURL = docs.appendingPathComponent("amach_baselines.json")
        pendingURL = docs.appendingPathComponent("amach_pending_insights.json")
        load()
    }

    // MARK: - HealthEvent API

    /// Record a new anomaly event. No-op if an active event for this metric already exists
    /// (prevents re-recording the same ongoing anomaly on every background check).
    func record(_ event: HealthEvent) {
        guard !hasActiveAnomaly(for: event.metricType) else { return }
        events.insert(event, at: 0)
        saveEvents()
    }

    /// Mark an active event as resolved.
    func resolve(eventId: UUID, outcome: EventOutcome = .resolved) {
        guard let idx = events.firstIndex(where: { $0.id == eventId }) else { return }
        events[idx].resolvedAt = .now
        events[idx].outcome = outcome
        saveEvents()
    }

    /// Attach the ChatSession that discussed this event.
    func linkSession(_ sessionId: UUID, to eventId: UUID) {
        guard let idx = events.firstIndex(where: { $0.id == eventId }) else { return }
        events[idx].lumaSessionId = sessionId
        saveEvents()
    }

    /// Attach a user-reported cause extracted from chat (e.g. "I was travelling").
    func attachCause(_ cause: String, to eventId: UUID) {
        guard let idx = events.firstIndex(where: { $0.id == eventId }) else { return }
        events[idx].userReportedCause = cause
        saveEvents()
    }

    /// Mark when Luma surfaced this event via notification.
    func markSurfaced(_ eventId: UUID) {
        guard let idx = events.firstIndex(where: { $0.id == eventId }) else { return }
        events[idx].lumaSurfacedAt = .now
        saveEvents()
    }

    /// Whether there is a currently unresolved event for a metric.
    func hasActiveAnomaly(for metricType: String) -> Bool {
        events.contains { $0.metricType == metricType && $0.outcome == nil }
    }

    /// Most recent N resolved+ongoing events for a metric — used to build Venice context.
    func recentEvents(for metricType: String, limit: Int = 3) -> [HealthEvent] {
        Array(
            events
                .filter { $0.metricType == metricType }
                .prefix(limit)
        )
    }

    /// Narrative summaries of prior events for Venice — kept terse, one sentence each.
    func priorNarratives(for metricType: String, limit: Int = 3) -> [String] {
        recentEvents(for: metricType, limit: limit)
            .filter { $0.outcome != nil }   // only resolved/dismissed — not the current one
            .map { $0.narrativeSummary }
    }

    // MARK: - MetricSensitivityProfile API

    /// Returns the profile for a metric, with any user sensitivity override applied.
    /// Falls back to MetricSensitivityProfile.defaults, then a generic medium profile.
    func profile(for metricType: String) -> MetricSensitivityProfile {
        var profile = MetricSensitivityProfile.defaults[metricType]
            ?? MetricSensitivityProfile(
                metricType: metricType,
                baseZScoreThreshold: 2.0,
                baseMinConsecutiveDays: 3,
                monitoredDirections: [],
                absoluteFloor: nil,
                absoluteCeiling: nil,
                sensitivityLevel: .medium
            )
        // Apply user override if set
        if let raw = UserDefaults.standard.string(forKey: "luma.sensitivity.\(metricType)"),
           let level = SensitivityLevel(rawValue: raw) {
            profile.sensitivityLevel = level
        }
        return profile
    }

    /// Persist a user's sensitivity preference for a metric.
    func setSensitivity(_ level: SensitivityLevel, for metricType: String) {
        UserDefaults.standard.set(level.rawValue, forKey: "luma.sensitivity.\(metricType)")
    }

    /// Reset a metric's sensitivity to its profile default.
    func resetSensitivity(for metricType: String) {
        UserDefaults.standard.removeObject(forKey: "luma.sensitivity.\(metricType)")
    }

    // MARK: - PersonalBaseline API

    func baseline(for metricType: String) -> PersonalBaseline? {
        baselines[metricType]
    }

    /// Update the running baseline for a metric with a new daily reading.
    /// Called by AnomalyDetector after each HealthKit sync.
    func updateBaseline(metricType: String, value: Double) {
        var baseline = baselines[metricType] ?? PersonalBaseline(metricType: metricType)
        baseline.update(with: value)
        baselines[metricType] = baseline
        saveBaselines()
    }

    /// Bulk-update baselines from a full daily summary map.
    /// Called after each HealthDataSyncService sync pass.
    func updateBaselines(from dailySummaries: [String: DailySummary]) {
        for (dateStr, summary) in dailySummaries {
            _ = dateStr  // used for ordering but we process all entries
            for (metricKey, metricSummary) in summary.metrics {
                if let value = metricSummary.avg ?? metricSummary.total {
                    updateBaseline(metricType: metricKey, value: value)
                }
            }
            if let sleep = summary.sleep {
                let sleepHours = Double(sleep.total) / 60.0
                updateBaseline(metricType: "sleepDuration", value: sleepHours)
                if let efficiency = sleep.efficiency {
                    updateBaseline(metricType: "sleepEfficiency", value: efficiency)
                }
            }
        }
    }

    // MARK: - Pending Insight API

    /// Stage a pending insight for delivery when the app next foregrounds.
    func stagePendingInsight(_ insight: PendingProactiveInsight) {
        pendingInsights.append(insight)
        savePending()
    }

    /// Consume and return the oldest undelivered pending insight, if any.
    func consumeNextPendingInsight() -> PendingProactiveInsight? {
        guard let idx = pendingInsights.firstIndex(where: { !$0.notificationFired }) else {
            return nil
        }
        pendingInsights[idx].notificationFired = true
        let insight = pendingInsights[idx]
        savePending()
        return insight
    }

    /// Clear all pending insights (e.g. if user dismisses from notification center).
    func clearPendingInsights() {
        pendingInsights.removeAll()
        savePending()
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: eventsURL),
           let decoded = try? JSONDecoder().decode([HealthEvent].self, from: data) {
            events = decoded
        }
        if let data = try? Data(contentsOf: baselinesURL),
           let decoded = try? JSONDecoder().decode([String: PersonalBaseline].self, from: data) {
            baselines = decoded
        }
        if let data = try? Data(contentsOf: pendingURL),
           let decoded = try? JSONDecoder().decode([PendingProactiveInsight].self, from: data) {
            pendingInsights = decoded
        }
    }

    private func saveEvents() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: eventsURL, options: .atomic)
    }

    private func saveBaselines() {
        guard let data = try? JSONEncoder().encode(baselines) else { return }
        try? data.write(to: baselinesURL, options: .atomic)
    }

    private func savePending() {
        guard let data = try? JSONEncoder().encode(pendingInsights) else { return }
        try? data.write(to: pendingURL, options: .atomic)
    }
}
