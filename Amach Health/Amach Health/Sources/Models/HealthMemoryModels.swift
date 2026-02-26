// HealthMemoryModels.swift
// AmachHealth
//
// Models for Luma's longitudinal health memory.
//
// Architecture:
//   HealthEvent      — a detected anomaly with its full lifecycle
//   PersonalBaseline — rolling per-metric statistics (Welford's algorithm)
//   AnomalySignal    — raw detector output, not yet persisted
//   ProactiveInsightContext — Venice context payload for Luma-initiated chats
//   ChatMessageMetadata     — tags proactive messages in ChatSession

import Foundation

// MARK: - Anomaly Direction

enum AnomalyDirection: String, Codable {
    case declining
    case spiking
    case unusualPattern

    var displayLabel: String {
        switch self {
        case .declining: return "declining"
        case .spiking: return "elevated"
        case .unusualPattern: return "behaving unusually"
        }
    }
}

// MARK: - Event Outcome

enum EventOutcome: String, Codable {
    case resolved       // metric returned within baseline range
    case ongoing        // still outside baseline at last check
    case userDismissed  // user acknowledged but did not engage
}

// MARK: - Anomaly Type

enum AnomalyType: String, Codable {
    case deviation      // value deviated from personal baseline by >2σ
    case trend          // sustained directional movement over N days
    case pattern        // matches a historical signature (e.g. pre-illness dip)
}

// MARK: - Health Event

/// A structured record of a significant health pattern detected by Luma.
/// Lives in HealthMemoryStore — separate from ChatSession.
/// These are what allow Luma to say "this happened before."
struct HealthEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let metricType: String          // "heartRateVariabilitySDNN"
    let anomalyType: AnomalyType
    let direction: AnomalyDirection
    let detectedAt: Date
    var resolvedAt: Date?           // nil while ongoing
    let baselineValue: Double       // personal mean at detection time
    let peakDeviation: Double       // most extreme reading during event
    let deviationPct: Double        // e.g. -28.2 (negative = below baseline)
    let durationDays: Int           // days anomaly was active at detection
    var userReportedCause: String?  // extracted from chat: "I was sick", "bad travel week"
    var outcome: EventOutcome?
    var lumaSessionId: UUID?        // ChatSession.id where this was discussed
    var lumaSurfacedAt: Date?       // when Luma sent the proactive notification

    init(
        metricType: String,
        anomalyType: AnomalyType,
        direction: AnomalyDirection,
        detectedAt: Date = .now,
        baselineValue: Double,
        peakDeviation: Double,
        deviationPct: Double,
        durationDays: Int
    ) {
        self.id = UUID()
        self.metricType = metricType
        self.anomalyType = anomalyType
        self.direction = direction
        self.detectedAt = detectedAt
        self.baselineValue = baselineValue
        self.peakDeviation = peakDeviation
        self.deviationPct = deviationPct
        self.durationDays = durationDays
    }

    /// Terse narrative injected into Venice context.
    /// Intentionally compact — many of these may be concatenated into a single prompt.
    var narrativeSummary: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let dateStr = formatter.string(from: detectedAt)
        let sign = deviationPct >= 0 ? "+" : ""
        var text = "\(dateStr): \(metricType) \(direction.displayLabel) "
            + "(\(sign)\(String(format: "%.0f", deviationPct))% from baseline, \(durationDays) days)"
        if let cause = userReportedCause {
            text += "; user reported: \(cause)"
        }
        if let resolved = resolvedAt {
            text += "; resolved \(formatter.string(from: resolved))"
        } else if outcome == .ongoing {
            text += "; still ongoing"
        }
        return text
    }
}

// MARK: - Personal Baseline

/// Rolling statistics for a single metric type.
/// Updated incrementally via Welford's online algorithm as new readings arrive.
/// Requires minSamplesRequired days before AnomalyDetector will trust it.
struct PersonalBaseline: Codable {
    let metricType: String
    var mean: Double
    var standardDeviation: Double
    var sampleCount: Int
    var lastUpdated: Date
    var recentValues: [Double]  // last 90 values — enough for stable rolling stats

    static let minSamplesRequired = 14  // 2 weeks minimum before detecting anomalies

    var isReliable: Bool { sampleCount >= PersonalBaseline.minSamplesRequired }

    init(metricType: String) {
        self.metricType = metricType
        self.mean = 0
        self.standardDeviation = 0
        self.sampleCount = 0
        self.lastUpdated = .now
        self.recentValues = []
    }

    /// Standard deviations `value` is from the mean.
    /// Positive = above mean, negative = below mean.
    func zScore(for value: Double) -> Double {
        guard standardDeviation > 0 else { return 0 }
        return (value - mean) / standardDeviation
    }

    /// Recomputes mean and SD from recentValues using Welford's method.
    mutating func update(with newValue: Double) {
        recentValues.append(newValue)
        if recentValues.count > 90 { recentValues.removeFirst() }
        sampleCount += 1

        let n = Double(recentValues.count)
        mean = recentValues.reduce(0, +) / n

        if recentValues.count > 1 {
            let variance = recentValues.map { pow($0 - mean, 2) }.reduce(0, +) / (n - 1)
            standardDeviation = sqrt(variance)
        }
        lastUpdated = .now
    }
}

// MARK: - Sensitivity Level

/// User-adjustable sensitivity for a metric's anomaly detection.
/// Applied as a multiplier to the default zScore threshold and min consecutive days.
enum SensitivityLevel: String, Codable, CaseIterable {
    case low    // fewer, higher-confidence alerts  (thresholds * 1.3)
    case medium // default
    case high   // more sensitive, earlier alerts  (thresholds * 0.7)

    var displayLabel: String {
        switch self {
        case .low:    return "Less sensitive"
        case .medium: return "Default"
        case .high:   return "More sensitive"
        }
    }
}

// MARK: - Metric Sensitivity Profile

/// Per-metric detection parameters. Every monitored metric has a default profile;
/// users can override the sensitivityLevel to tune alerting to their lifestyle.
///
/// Design principles:
///   - Absolute floors/ceilings bypass statistics for clinically meaningful values
///   - monitoredDirections prevents noise from "good" deviations (e.g. high HRV)
///   - Consecutive day windows are tuned to each metric's natural variability
struct MetricSensitivityProfile {
    let metricType: String

    /// σ threshold for statistical significance (before sensitivity multiplier).
    let baseZScoreThreshold: Double

    /// Minimum consecutive days outside baseline to surface (before multiplier).
    let baseMinConsecutiveDays: Int

    /// Only alert for these directions. Empty = alert for both.
    let monitoredDirections: [AnomalyDirection]

    /// Value below this is always significant, regardless of personal baseline.
    let absoluteFloor: Double?

    /// Value above this is always significant, regardless of personal baseline.
    let absoluteCeiling: Double?

    /// User-adjustable — the only field that changes after initialization.
    var sensitivityLevel: SensitivityLevel

    // MARK: Effective thresholds (after sensitivity multiplier)

    var effectiveZScore: Double {
        switch sensitivityLevel {
        case .low:    return baseZScoreThreshold * 1.3
        case .medium: return baseZScoreThreshold
        case .high:   return baseZScoreThreshold * 0.7
        }
    }

    var effectiveMinDays: Int {
        switch sensitivityLevel {
        case .low:    return baseMinConsecutiveDays + 2
        case .medium: return baseMinConsecutiveDays
        case .high:   return max(1, baseMinConsecutiveDays - 1)
        }
    }

    /// Resolution threshold — hysteresis below detection so we don't
    /// flip in and out on borderline readings.
    var resolutionZScore: Double { effectiveZScore * 0.65 }

    // MARK: - Default profiles

    /// Defaults for all monitored metrics. Each profile reflects the metric's
    /// natural variability and clinical significance.
    static let defaults: [String: MetricSensitivityProfile] = [

        // HRV — noisiest metric but most sensitive to stress/illness.
        // Only declining matters: high HRV is healthy.
        "heartRateVariabilitySDNN": MetricSensitivityProfile(
            metricType: "heartRateVariabilitySDNN",
            baseZScoreThreshold: 2.0,
            baseMinConsecutiveDays: 3,
            monitoredDirections: [.declining],
            absoluteFloor: nil,
            absoluteCeiling: nil,
            sensitivityLevel: .medium
        ),

        // RHR — stable day-to-day; a sustained elevation is a reliable illness signal.
        // Only spiking matters: low RHR is healthy. Hard ceiling at 100 bpm (tachycardia).
        "restingHeartRate": MetricSensitivityProfile(
            metricType: "restingHeartRate",
            baseZScoreThreshold: 1.8,
            baseMinConsecutiveDays: 2,
            monitoredDirections: [.spiking],
            absoluteFloor: nil,
            absoluteCeiling: 100,
            sensitivityLevel: .medium
        ),

        // Sleep duration — highly variable; need a longer window to distinguish
        // pattern from noise. Both directions matter: chronic short AND long sleep.
        "sleepDuration": MetricSensitivityProfile(
            metricType: "sleepDuration",
            baseZScoreThreshold: 2.0,
            baseMinConsecutiveDays: 5,
            monitoredDirections: [.declining, .spiking],
            absoluteFloor: 4.0,     // <4 h/night = severe deprivation regardless of baseline
            absoluteCeiling: nil,
            sensitivityLevel: .medium
        ),

        // Sleep efficiency — only low efficiency is concerning.
        // Hard floor at 70%: below that sleep is fragmented regardless of personal norm.
        "sleepEfficiency": MetricSensitivityProfile(
            metricType: "sleepEfficiency",
            baseZScoreThreshold: 2.0,
            baseMinConsecutiveDays: 4,
            monitoredDirections: [.declining],
            absoluteFloor: 70,
            absoluteCeiling: nil,
            sensitivityLevel: .medium
        ),

        // Step count — very noisy (weekend vs weekday, weather, travel).
        // High threshold + long window to avoid lifestyle-driven false positives.
        "stepCount": MetricSensitivityProfile(
            metricType: "stepCount",
            baseZScoreThreshold: 2.5,
            baseMinConsecutiveDays: 7,
            monitoredDirections: [.declining],
            absoluteFloor: nil,
            absoluteCeiling: nil,
            sensitivityLevel: .medium
        ),

        // Active energy — similar variability to steps; week-long window needed.
        "activeEnergyBurned": MetricSensitivityProfile(
            metricType: "activeEnergyBurned",
            baseZScoreThreshold: 2.5,
            baseMinConsecutiveDays: 7,
            monitoredDirections: [.declining],
            absoluteFloor: nil,
            absoluteCeiling: nil,
            sensitivityLevel: .medium
        ),

        // Respiratory rate — early illness indicator. Lower threshold + shorter window
        // than activity metrics. Hard ceiling at 20 breaths/min (elevated at rest).
        "respiratoryRate": MetricSensitivityProfile(
            metricType: "respiratoryRate",
            baseZScoreThreshold: 1.8,
            baseMinConsecutiveDays: 2,
            monitoredDirections: [.spiking],
            absoluteFloor: nil,
            absoluteCeiling: 20,
            sensitivityLevel: .medium
        ),

        // SpO2 — most clinically critical metric.
        // Low threshold, single-day window: even one concerning reading matters.
        // Hard floor at 94%: below that is clinically significant regardless of baseline.
        "oxygenSaturation": MetricSensitivityProfile(
            metricType: "oxygenSaturation",
            baseZScoreThreshold: 1.5,
            baseMinConsecutiveDays: 1,
            monitoredDirections: [.declining],
            absoluteFloor: 94,
            absoluteCeiling: nil,
            sensitivityLevel: .medium
        ),
    ]
}

// MARK: - Anomaly Signal

/// Raw output from AnomalyDetector — one signal per evaluated metric.
/// Not persisted. Converted to HealthEvent only if significant enough to surface.
struct AnomalySignal {
    let metricType: String
    let currentValue: Double
    let baseline: PersonalBaseline
    let zScore: Double
    let direction: AnomalyDirection
    let consecutiveDaysOutside: Int  // consecutive days in the *detected direction*

    /// Evaluate significance against a specific metric profile.
    /// Absolute floors/ceilings bypass statistical checks entirely.
    func isSignificant(using profile: MetricSensitivityProfile) -> Bool {
        // Absolute clinical thresholds — no statistical model needed
        if let floor = profile.absoluteFloor, currentValue < floor { return true }
        if let ceiling = profile.absoluteCeiling, currentValue > ceiling { return true }

        // Ignore deviations in directions this metric doesn't care about
        if !profile.monitoredDirections.isEmpty,
           !profile.monitoredDirections.contains(direction) { return false }

        // Statistical significance: sustained deviation above profile threshold
        return abs(zScore) >= profile.effectiveZScore
            && consecutiveDaysOutside >= profile.effectiveMinDays
    }

    func toHealthEvent(using profile: MetricSensitivityProfile) -> HealthEvent? {
        guard isSignificant(using: profile) else { return nil }
        return HealthEvent(
            metricType: metricType,
            anomalyType: .deviation,
            direction: direction,
            baselineValue: baseline.mean,
            peakDeviation: currentValue,
            deviationPct: ((currentValue - baseline.mean) / baseline.mean) * 100,
            durationDays: consecutiveDaysOutside
        )
    }
}

// MARK: - Proactive Insight Context

/// Full Venice context payload for a Luma-initiated conversation.
/// Includes the live anomaly + relevant prior events for longitudinal matching.
struct ProactiveInsightContext: Encodable {
    let screen: String              // always "proactive_insight"
    let triggerType: String         // always "anomaly_detected"
    let anomaly: AnomalyPayload
    let priorEvents: [PriorEventPayload]
    let relevantSessionSummaries: [String]  // distilled from HealthEvent.narrativeSummary

    struct AnomalyPayload: Encodable {
        let metricType: String
        let baselineValue: Double
        let currentValue: Double
        let deviationPct: Double
        let durationDays: Int
        let direction: String
    }

    struct PriorEventPayload: Encodable {
        let summary: String     // HealthEvent.narrativeSummary — terse, ~1 sentence
        let daysSince: Int      // how long ago this event occurred
    }
}

// MARK: - Pending Proactive Insight

/// Stored locally between anomaly detection (background) and Venice call (foreground).
/// The notification fires with templated text; Venice generates the full message on open.
struct PendingProactiveInsight: Codable, Identifiable, Equatable {
    let id: UUID
    let healthEventId: UUID
    let createdAt: Date
    var notificationFired: Bool
    let notificationText: String    // on-device templated text for the notification body

    init(healthEventId: UUID, notificationText: String) {
        self.id = UUID()
        self.healthEventId = healthEventId
        self.createdAt = .now
        self.notificationFired = false
        self.notificationText = notificationText
    }
}

// MARK: - ChatMessage Metadata

/// Optional tag on ChatMessage identifying Luma-initiated messages
/// and linking them back to the HealthEvent that triggered them.
struct ChatMessageMetadata: Codable {
    let triggerType: String?        // "proactive_anomaly" | nil for normal messages
    let healthEventId: UUID?        // links back to HealthMemoryStore
    let isLumaInitiated: Bool
}
