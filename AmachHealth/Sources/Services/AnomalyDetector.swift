// AnomalyDetector.swift
// AmachHealth
//
// Evaluates incoming HealthKit daily readings against PersonalBaselines,
// using per-metric MetricSensitivityProfiles from HealthMemoryStore.
//
// Each metric has its own:
//   - zScore threshold     (SpO2: 1.5σ vs steps: 2.5σ)
//   - consecutive day window  (SpO2: 1 day vs steps: 7 days)
//   - monitored directions    (HRV: declining only; sleep: both)
//   - absolute clinical floors/ceilings (SpO2 < 94 always significant)
//   - user sensitivity override (low / medium / high)
//
// Consecutive day counters are direction-aware — a week of elevated steps
// does not count toward the declining-steps anomaly window.

import Foundation

@MainActor
final class AnomalyDetector {

    // Monitored metrics — the superset. Profiles define how each is evaluated.
    static let monitoredMetrics: Set<String> = Set(MetricSensitivityProfile.defaults.keys)

    // Direction-aware consecutive day counters.
    // Key: "\(metricType)_\(direction.rawValue)" — e.g. "restingHeartRate_spiking"
    // Crossing in the opposite direction resets only the opposite counter.
    private var consecutiveDaysOutside: [String: Int] = [:]

    private let store: HealthMemoryStore

    init(store: HealthMemoryStore) {
        self.store = store
    }

    // MARK: - Main evaluation entry point

    /// Evaluate a map of daily summaries against stored baselines.
    /// Returns significant anomaly signals sorted by severity (highest |zScore| first).
    func evaluate(dailySummaries: [String: DailySummary]) -> [AnomalySignal] {
        let sortedDays = dailySummaries.keys.sorted()
        var signals: [AnomalySignal] = []

        for dateKey in sortedDays {
            guard let summary = dailySummaries[dateKey] else { continue }
            signals.append(contentsOf: evaluateDay(summary: summary))
        }

        // Filter and rank — highest absolute deviation first
        return signals
            .filter { signal in
                let profile = store.profile(for: signal.metricType)
                return signal.isSignificant(using: profile)
            }
            .sorted { abs($0.zScore) > abs($1.zScore) }
    }

    /// Evaluate a single day's readings against all monitored metrics.
    private func evaluateDay(summary: DailySummary) -> [AnomalySignal] {
        let readings = flattenReadings(from: summary)
        var signals: [AnomalySignal] = []

        for metricType in Self.monitoredMetrics {
            guard let value = readings[metricType] else { continue }
            guard let baseline = store.baseline(for: metricType),
                  baseline.isReliable else { continue }

            let profile = store.profile(for: metricType)
            let z = baseline.zScore(for: value)
            guard z != 0 else { continue }

            let direction: AnomalyDirection = z < 0 ? .declining : .spiking

            // Update direction-aware consecutive day counters.
            // A day above baseline resets the declining counter (and vice versa).
            let detectedKey  = consecutiveDayKey(metricType, direction)
            let oppositeKey  = consecutiveDayKey(metricType, direction == .declining ? .spiking : .declining)

            let isOutsideThreshold = abs(z) >= profile.effectiveZScore
                || (profile.absoluteFloor.map { value < $0 } ?? false)
                || (profile.absoluteCeiling.map { value > $0 } ?? false)

            if isOutsideThreshold {
                consecutiveDaysOutside[detectedKey, default: 0] += 1
                consecutiveDaysOutside[oppositeKey] = 0
            } else {
                consecutiveDaysOutside[detectedKey] = 0
            }

            let signal = AnomalySignal(
                metricType: metricType,
                currentValue: value,
                baseline: baseline,
                zScore: z,
                direction: direction,
                consecutiveDaysOutside: consecutiveDaysOutside[detectedKey, default: 0]
            )
            signals.append(signal)
        }

        return signals
    }

    // MARK: - Resolution check

    /// Check whether previously-active anomalies have returned to baseline.
    /// Uses each metric's profile resolutionZScore (below detection threshold)
    /// to avoid flipping in and out on borderline readings.
    func checkResolutions(from dailySummaries: [String: DailySummary]) {
        let activeEvents = store.events.filter { $0.outcome == nil }
        guard !activeEvents.isEmpty else { return }

        guard let latestDate = dailySummaries.keys.sorted().last,
              let latestSummary = dailySummaries[latestDate] else { return }

        let readings = flattenReadings(from: latestSummary)

        for event in activeEvents {
            guard let currentValue = readings[event.metricType],
                  let baseline = store.baseline(for: event.metricType),
                  baseline.isReliable else { continue }

            let profile = store.profile(for: event.metricType)
            let z = abs(baseline.zScore(for: currentValue))

            // Also check absolute thresholds — if we're back above the floor, resolved
            let aboveFloor   = profile.absoluteFloor.map { currentValue >= $0 } ?? true
            let belowCeiling = profile.absoluteCeiling.map { currentValue <= $0 } ?? true

            if z < profile.resolutionZScore && aboveFloor && belowCeiling {
                consecutiveDaysOutside[consecutiveDayKey(event.metricType, event.direction)] = 0
                Task { @MainActor in
                    store.resolve(eventId: event.id, outcome: .resolved)
                }
            }
        }
    }

    // MARK: - Helpers

    /// Flatten a DailySummary into a flat [metricType: value] map.
    /// Sleep metrics are derived here so all downstream code sees a uniform interface.
    private func flattenReadings(from summary: DailySummary) -> [String: Double] {
        var readings: [String: Double] = [:]
        for (key, metric) in summary.metrics {
            if let value = metric.avg ?? metric.total {
                readings[key] = value
            }
        }
        if let sleep = summary.sleep {
            readings["sleepDuration"] = Double(sleep.total) / 60.0
            if let efficiency = sleep.efficiency {
                readings["sleepEfficiency"] = efficiency
            }
        }
        return readings
    }

    private func consecutiveDayKey(_ metricType: String, _ direction: AnomalyDirection) -> String {
        "\(metricType)_\(direction.rawValue)"
    }
}
