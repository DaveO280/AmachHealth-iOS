// TimelineModels.swift
// AmachHealth
//
// Cross-platform models for timeline events and manually entered lab records.

import Foundation

// MARK: - Timeline Event Type

enum TimelineEventType: String, Codable, CaseIterable, Identifiable {
    case medicationStarted = "MEDICATION_STARTED"
    case medicationStopped = "MEDICATION_STOPPED"
    case supplementStarted = "SUPPLEMENT_STARTED"
    case supplementStopped = "SUPPLEMENT_STOPPED"
    case conditionDiagnosed = "CONDITION_DIAGNOSED"
    case conditionResolved = "CONDITION_RESOLVED"
    case injuryOccurred = "INJURY_OCCURRED"
    case injuryResolved = "INJURY_RESOLVED"
    case surgeryProcedure = "SURGERY_PROCEDURE"
    case labResults = "LAB_RESULTS"
    case lifestyleChange = "LIFESTYLE_CHANGE"
    case dietChange = "DIET_CHANGE"
    case exerciseChange = "EXERCISE_CHANGE"
    case stressEvent = "STRESS_EVENT"
    case sleepChange = "SLEEP_CHANGE"
    case generalNote = "GENERAL_NOTE"
    case custom = "CUSTOM"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .medicationStarted: return "Medication Started"
        case .medicationStopped: return "Medication Stopped"
        case .supplementStarted: return "Supplement Started"
        case .supplementStopped: return "Supplement Stopped"
        case .conditionDiagnosed: return "Condition Diagnosed"
        case .conditionResolved: return "Condition Resolved"
        case .injuryOccurred: return "Injury Occurred"
        case .injuryResolved: return "Injury Resolved"
        case .surgeryProcedure: return "Surgery or Procedure"
        case .labResults: return "Lab Results"
        case .lifestyleChange: return "Lifestyle Change"
        case .dietChange: return "Diet Change"
        case .exerciseChange: return "Exercise Change"
        case .stressEvent: return "Stress Event"
        case .sleepChange: return "Sleep Change"
        case .generalNote: return "General Note"
        case .custom: return "Custom Event"
        }
    }

    var icon: String {
        switch self {
        case .medicationStarted: return "pills.fill"
        case .medicationStopped: return "nosign"
        case .supplementStarted: return "leaf.fill"
        case .supplementStopped: return "leaf.circle"
        case .conditionDiagnosed: return "cross.case.fill"
        case .conditionResolved: return "checkmark.circle.fill"
        case .injuryOccurred: return "bandage.fill"
        case .injuryResolved: return "cross.case.circle"
        case .surgeryProcedure: return "stethoscope"
        case .labResults: return "testtube.2"
        case .lifestyleChange: return "figure.walk.motion"
        case .dietChange: return "fork.knife"
        case .exerciseChange: return "figure.run"
        case .stressEvent: return "bolt.heart.fill"
        case .sleepChange: return "bed.double.fill"
        case .generalNote: return "note.text"
        case .custom: return "square.and.pencil"
        }
    }

    var fields: [TimelineEventField] {
        switch self {
        case .medicationStarted:
            return [
                .init(key: "name", label: "Medication name", placeholder: "Metformin", required: true),
                .init(key: "dosage", label: "Dosage", placeholder: "500mg", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Prescribed for glucose control", required: false)
            ]
        case .medicationStopped:
            return [
                .init(key: "name", label: "Medication name", placeholder: "Metformin", required: true),
                .init(key: "reason", label: "Reason", placeholder: "Completed course", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Stopped with clinician guidance", required: false)
            ]
        case .supplementStarted:
            return [
                .init(key: "name", label: "Supplement name", placeholder: "Magnesium glycinate", required: true),
                .init(key: "dosage", label: "Dosage", placeholder: "300mg", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Started for sleep support", required: false)
            ]
        case .supplementStopped:
            return [
                .init(key: "name", label: "Supplement name", placeholder: "Magnesium glycinate", required: true),
                .init(key: "reason", label: "Reason", placeholder: "No longer needed", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Any side effects or observations", required: false)
            ]
        case .conditionDiagnosed:
            return [
                .init(key: "condition", label: "Condition", placeholder: "Hashimoto's", required: true),
                .init(key: "diagnosedBy", label: "Diagnosed by", placeholder: "Endocrinologist", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Relevant context or symptoms", required: false)
            ]
        case .conditionResolved:
            return [
                .init(key: "condition", label: "Condition", placeholder: "Iron deficiency", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Resolution details", required: false)
            ]
        case .injuryOccurred:
            return [
                .init(key: "injury", label: "Injury", placeholder: "Right ankle sprain", required: true),
                .init(key: "severity", label: "Severity", placeholder: "Mild", required: false),
                .init(key: "notes", label: "Notes", placeholder: "How it happened", required: false)
            ]
        case .injuryResolved:
            return [
                .init(key: "injury", label: "Injury", placeholder: "Right ankle sprain", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Recovery details", required: false)
            ]
        case .surgeryProcedure:
            return [
                .init(key: "procedure", label: "Procedure", placeholder: "ACL reconstruction", required: true),
                .init(key: "provider", label: "Provider", placeholder: "Hospital or clinician", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Outcome or follow-up details", required: false)
            ]
        case .labResults:
            return [
                .init(key: "panel", label: "Panel or test", placeholder: "CMP + lipid panel", required: true),
                .init(key: "highlight", label: "Key result", placeholder: "HbA1c 5.2%", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Fasting, morning draw", required: false)
            ]
        case .lifestyleChange:
            return [
                .init(key: "change", label: "Change", placeholder: "Started intermittent fasting", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Schedule or motivation", required: false)
            ]
        case .dietChange:
            return [
                .init(key: "change", label: "Diet change", placeholder: "Higher protein breakfast", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Any specific target or protocol", required: false)
            ]
        case .exerciseChange:
            return [
                .init(key: "change", label: "Exercise change", placeholder: "Added 3 weekly zone 2 sessions", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Volume, intensity, or goal", required: false)
            ]
        case .stressEvent:
            return [
                .init(key: "event", label: "Stress event", placeholder: "Travel week", required: true),
                .init(key: "notes", label: "Notes", placeholder: "What changed and for how long", required: false)
            ]
        case .sleepChange:
            return [
                .init(key: "change", label: "Sleep change", placeholder: "Started going to bed at 10pm", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Observed impact so far", required: false)
            ]
        case .generalNote:
            return [
                .init(key: "title", label: "Title", placeholder: "General health note", required: false),
                .init(key: "notes", label: "Note", placeholder: "What happened?", required: true)
            ]
        case .custom:
            return [
                .init(key: "title", label: "Title", placeholder: "Custom event", required: true),
                .init(key: "details", label: "Details", placeholder: "Add context", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Optional notes", required: false)
            ]
        }
    }
}

// MARK: - Timeline Field

struct TimelineEventField: Hashable {
    let key: String
    let label: String
    let placeholder: String
    let required: Bool
}

// MARK: - Timeline Event

struct TimelineEvent: Identifiable, Codable, Equatable {
    let id: String
    let eventType: TimelineEventType
    let timestamp: Date
    var data: [String: String]
    var metadata: TimelineEventMetadata
    var anomalyType: String?
    var metricType: String?
    var direction: String?
    var deviationPct: Double?
    var resolvedAt: Date?
    var attestationTxHash: String?

    var isAnomaly: Bool {
        metadata.source == .autoDetected || anomalyType != nil
    }

    var titleText: String {
        if isAnomaly, let metricType {
            return "\(metricType.timelineMetricName) anomaly"
        }
        return eventType.displayName
    }

    var subtitleText: String? {
        if isAnomaly {
            if let deviationPct {
                let sign = deviationPct > 0 ? "+" : ""
                return "\(sign)\(Int(deviationPct.rounded()))% vs baseline"
            }
            return nil
        }

        let orderedKeys = ["name", "condition", "injury", "procedure", "panel", "change", "event", "title", "notes"]
        for key in orderedKeys {
            if let value = data[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return data.values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    init(
        id: String,
        eventType: TimelineEventType,
        timestamp: Date,
        data: [String: String],
        metadata: TimelineEventMetadata,
        anomalyType: String? = nil,
        metricType: String? = nil,
        direction: String? = nil,
        deviationPct: Double? = nil,
        resolvedAt: Date? = nil,
        attestationTxHash: String? = nil
    ) {
        self.id = id
        self.eventType = eventType
        self.timestamp = timestamp
        self.data = data
        self.metadata = metadata
        self.anomalyType = anomalyType
        self.metricType = metricType
        self.direction = direction
        self.deviationPct = deviationPct
        self.resolvedAt = resolvedAt
        self.attestationTxHash = attestationTxHash
    }
}

extension TimelineEvent {
    init(fromHealthEvent event: HealthEvent) {
        self.init(
            id: "anomaly-\(event.id.uuidString.lowercased())",
            eventType: .generalNote,
            timestamp: event.detectedAt,
            data: [
                "summary": event.narrativeSummary,
                "metric": event.metricType.timelineMetricName
            ],
            metadata: TimelineEventMetadata(
                platform: "ios",
                version: "1",
                source: .autoDetected
            ),
            anomalyType: event.anomalyType.rawValue,
            metricType: event.metricType,
            direction: event.direction.rawValue,
            deviationPct: event.deviationPct,
            resolvedAt: event.resolvedAt,
            attestationTxHash: nil
        )
    }
}

// MARK: - Timeline Metadata

struct TimelineEventMetadata: Codable, Equatable {
    let platform: String
    let version: String
    let source: TimelineEventSource
}

enum TimelineEventSource: String, Codable {
    case userEntered = "user"
    case autoDetected = "auto"
}

// MARK: - Lab Record

struct LabRecord: Identifiable, Codable, Equatable {
    let id: String
    let date: Date
    let type: String
    let values: [String: Double]
    let units: [String: String]
    let notes: String?
    var attestationTxHash: String?

    var title: String {
        switch type {
        case "bloodwork":
            return "Bloodwork"
        case "dexa":
            return "DEXA Scan"
        default:
            return "Lab Record"
        }
    }
}

// MARK: - Helpers

private extension String {
    var timelineMetricName: String {
        switch self {
        case "heartRateVariabilitySDNN":
            return "HRV"
        case "restingHeartRate":
            return "Resting Heart Rate"
        case "sleepDuration":
            return "Sleep Duration"
        case "sleepEfficiency":
            return "Sleep Efficiency"
        case "stepCount":
            return "Steps"
        case "activeEnergyBurned":
            return "Active Energy"
        case "respiratoryRate":
            return "Respiratory Rate"
        case "oxygenSaturation":
            return "Oxygen Saturation"
        default:
            return self
                .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .capitalized
        }
    }
}
