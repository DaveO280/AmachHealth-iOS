// AnomalyDetector.swift
// AmachHealth
//
// Evaluates incoming HealthKit daily readings against PersonalBaselines
// stored in HealthMemoryStore. Entirely on-device — no network calls.
//
// Significance threshold: >2σ deviation held for 3+ consecutive days.
// This filters single-day outliers (bad sleep night, travel day, etc.)
// and only surfaces patterns that are sustained and meaningful.
//
// Called by LumaProactiveService after each HealthKit sync or background
// observer fire. Returns [AnomalySignal] — caller decides what to surface.

import Foundation

final class AnomalyDetector {

    // MARK: - Core metrics monitored for anomalies
    //
    // Not every metric is worth monitoring proactively.
    // These are the ones with strong signal-to-noise for longitudinal patterns.

    static let monitoredMetrics: Set<String> = [
        "heartRateVariabilitySDNN",     // HRV — most sensitive stress/illness signal
        "restingHeartRate",             // RHR — elevated RHR tracks recovery/illness
        "sleepDuration",                // computed from SleepSummary.total
        "sleepEfficiency",              // computed from SleepSummary.efficiency
        "stepCount",                    // activity level proxy
        "activeEnergyBurned",           // workout intensity proxy
        "respiratoryRate",              // respiratory changes precede illness
        "oxygenSaturation",             // SpO2 — significant drops warrant attention
    ]

    // Tracks consecutive days each metric has been outside its baseline.
    // Keyed by metricType. Persists across calls within a session;
    // HealthMemoryStore holds the ground truth across app launches.
    private var consecutiveDaysOutside: [String: Int] = [:]

    private let store: HealthMemoryStore

    init(store: HealthMemoryStore = .shared) {
        self.store = store
    }

    // MARK: - Main evaluation entry point

    /// Evaluate a map of daily summaries against stored baselines.
    /// Returns significant anomaly signals sorted by severity (highest zScore first).
    ///
    /// - Parameter dailySummaries: keyed by "YYYY-MM-DD", from HealthKitService
    /// - Returns: signals that crossed the significance threshold
    func evaluate(dailySummaries: [String: DailySummary]) -> [AnomalySignal] {
        // Sort by date so we process in chronological order —
        // consecutive day counting depends on ordering
        let sortedDays = dailySummaries.keys.sorted()

        var signals: [AnomalySignal] = []

        for dateKey in sortedDays {
            guard let summary = dailySummaries[dateKey] else { continue }
            let daySignals = evaluateDay(summary: summary, date: dateKey)
            signals.append(contentsOf: daySignals)
        }

        // Return only significant signals, highest deviation first
        return signals
            .filter { $0.isSignificant }
            .sorted { abs($0.zScore) > abs($1.zScore) }
    }

    /// Evaluate a single day's readings.
    private func evaluateDay(summary: DailySummary, date: String) -> [AnomalySignal] {
        var signals: [AnomalySignal] = []

        // Metric readings from the daily summary
        var readings: [String: Double] = [:]
        for (key, metric) in summary.metrics {
            if let value = metric.avg ?? metric.total {
                readings[key] = value
            }
        }

        // Sleep metrics computed separately
        if let sleep = summary.sleep {
            readings["sleepDuration"] = Double(sleep.total) / 60.0
            if let efficiency = sleep.efficiency {
                readings["sleepEfficiency"] = efficiency
            }
        }

        for metricType in Self.monitoredMetrics {
            guard let value = readings[metricType] else { continue }
            guard let baseline = store.baseline(for: metricType),
                  baseline.isReliable else { continue }

            let z = baseline.zScore(for: value)
            guard abs(z) > 0 else { continue }

            let direction: AnomalyDirection = z < 0 ? .declining : .spiking
            let isOutside = abs(z) >= 2.0

            // Update consecutive days counter
            if isOutside {
                consecutiveDaysOutside[metricType, default: 0] += 1
            } else {
                consecutiveDaysOutside[metricType] = 0
            }

            let signal = AnomalySignal(
                metricType: metricType,
                currentValue: value,
                baseline: baseline,
                zScore: z,
                direction: direction,
                consecutiveDaysOutside: consecutiveDaysOutside[metricType, default: 0]
            )

            if signal.isSignificant {
                signals.append(signal)
            }
        }

        return signals
    }

    // MARK: - Resolution check

    /// Check whether previously-flagged anomalies have resolved.
    /// Called after baseline update to close out stale active events.
    func checkResolutions(from dailySummaries: [String: DailySummary]) {
        let activeEvents = store.events.filter { $0.outcome == nil }
        guard !activeEvents.isEmpty else { return }

        // Use the most recent day's readings for resolution check
        guard let latestDate = dailySummaries.keys.sorted().last,
              let latestSummary = dailySummaries[latestDate] else { return }

        var readings: [String: Double] = [:]
        for (key, metric) in latestSummary.metrics {
            if let value = metric.avg ?? metric.total {
                readings[key] = value
            }
        }
        if let sleep = latestSummary.sleep {
            readings["sleepDuration"] = Double(sleep.total) / 60.0
        }

        for event in activeEvents {
            guard let currentValue = readings[event.metricType],
                  let baseline = store.baseline(for: event.metricType),
                  baseline.isReliable else { continue }

            let z = abs(baseline.zScore(for: currentValue))
            if z < 1.5 {
                // Returned within ~1.5σ of baseline — consider resolved
                consecutiveDaysOutside[event.metricType] = 0
                Task { @MainActor in
                    store.resolve(eventId: event.id, outcome: .resolved)
                }
            }
        }
    }
}
