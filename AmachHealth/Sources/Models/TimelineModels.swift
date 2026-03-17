// TimelineModels.swift
// AmachHealth
//
// Cross-platform models for timeline events and manually entered lab records.

import Foundation

// MARK: - Timeline Event Type

enum TimelineEventType: String, Codable, CaseIterable, Identifiable {
    case medicationStarted = "MEDICATION_STARTED"
    case medicationStopped = "MEDICATION_STOPPED"
    case medicationDosageChanged = "MEDICATION_DOSAGE_CHANGED"
    case supplementStarted = "SUPPLEMENT_STARTED"
    case supplementStopped = "SUPPLEMENT_STOPPED"
    case conditionDiagnosed = "CONDITION_DIAGNOSED"
    case conditionResolved = "CONDITION_RESOLVED"
    case conditionImproved = "CONDITION_IMPROVED"
    case injuryOccurred = "INJURY_OCCURRED"
    case injuryResolved = "INJURY_RESOLVED"
    case injuryHealed = "INJURY_HEALED"
    case illnessStarted = "ILLNESS_STARTED"
    case illnessResolved = "ILLNESS_RESOLVED"
    case surgeryProcedure = "SURGERY_PROCEDURE"
    case surgeryCompleted = "SURGERY_COMPLETED"
    case procedureCompleted = "PROCEDURE_COMPLETED"
    case allergyAdded = "ALLERGY_ADDED"
    case allergyReaction = "ALLERGY_REACTION"
    case weightRecorded = "WEIGHT_RECORDED"
    case heightRecorded = "HEIGHT_RECORDED"
    case bloodPressureRecorded = "BLOOD_PRESSURE_RECORDED"
    case metricSnapshot = "METRIC_SNAPSHOT"
    case labResults = "LAB_RESULTS"
    case lifestyleChange = "LIFESTYLE_CHANGE"
    case dietChange = "DIET_CHANGE"
    case exerciseChange = "EXERCISE_CHANGE"
    case stressEvent = "STRESS_EVENT"
    case sleepChange = "SLEEP_CHANGE"
    case generalNote = "GENERAL_NOTE"
    case custom = "CUSTOM"

    var id: String { rawValue }

    /// Decode unknown web event types as `.custom` instead of failing.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = TimelineEventType(rawValue: rawValue) ?? .custom
    }

    var displayName: String {
        switch self {
        case .medicationStarted: return "Medication Started"
        case .medicationStopped: return "Medication Stopped"
        case .medicationDosageChanged: return "Dosage Changed"
        case .supplementStarted: return "Supplement Started"
        case .supplementStopped: return "Supplement Stopped"
        case .conditionDiagnosed: return "Condition Diagnosed"
        case .conditionResolved: return "Condition Resolved"
        case .conditionImproved: return "Condition Improved"
        case .injuryOccurred: return "Injury Occurred"
        case .injuryResolved: return "Injury Resolved"
        case .injuryHealed: return "Injury Healed"
        case .illnessStarted: return "Illness Started"
        case .illnessResolved: return "Illness Resolved"
        case .surgeryProcedure: return "Surgery or Procedure"
        case .surgeryCompleted: return "Surgery Completed"
        case .procedureCompleted: return "Procedure Completed"
        case .allergyAdded: return "Allergy Added"
        case .allergyReaction: return "Allergy Reaction"
        case .weightRecorded: return "Weight Recorded"
        case .heightRecorded: return "Height Recorded"
        case .bloodPressureRecorded: return "Blood Pressure"
        case .metricSnapshot: return "Health Snapshot"
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
        case .medicationDosageChanged: return "pills.circle"
        case .supplementStarted: return "leaf.fill"
        case .supplementStopped: return "leaf.circle"
        case .conditionDiagnosed: return "cross.case.fill"
        case .conditionResolved: return "checkmark.circle.fill"
        case .conditionImproved: return "arrow.up.heart.fill"
        case .injuryOccurred: return "bandage.fill"
        case .injuryResolved, .injuryHealed: return "cross.case.circle"
        case .illnessStarted: return "microbe.fill"
        case .illnessResolved: return "checkmark.seal.fill"
        case .surgeryProcedure, .surgeryCompleted: return "stethoscope"
        case .procedureCompleted: return "stethoscope.circle"
        case .allergyAdded: return "allergens.fill"
        case .allergyReaction: return "exclamationmark.triangle.fill"
        case .weightRecorded: return "scalemass.fill"
        case .heightRecorded: return "ruler.fill"
        case .bloodPressureRecorded: return "heart.text.clipboard.fill"
        case .metricSnapshot: return "chart.bar.doc.horizontal.fill"
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
        case .medicationDosageChanged:
            return [
                .init(key: "name", label: "Medication name", placeholder: "Metformin", required: true),
                .init(key: "previousDosage", label: "Previous dosage", placeholder: "500mg", required: false),
                .init(key: "newDosage", label: "New dosage", placeholder: "1000mg", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Reason for change", required: false)
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
        case .conditionImproved:
            return [
                .init(key: "condition", label: "Condition", placeholder: "Chronic fatigue", required: true),
                .init(key: "notes", label: "Notes", placeholder: "What improved", required: false)
            ]
        case .injuryOccurred:
            return [
                .init(key: "injury", label: "Injury", placeholder: "Right ankle sprain", required: true),
                .init(key: "severity", label: "Severity", placeholder: "Mild", required: false),
                .init(key: "notes", label: "Notes", placeholder: "How it happened", required: false)
            ]
        case .injuryResolved, .injuryHealed:
            return [
                .init(key: "injury", label: "Injury", placeholder: "Right ankle sprain", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Recovery details", required: false)
            ]
        case .illnessStarted:
            return [
                .init(key: "illness", label: "Illness", placeholder: "Cold/Flu", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Symptoms", required: false)
            ]
        case .illnessResolved:
            return [
                .init(key: "illness", label: "Illness", placeholder: "Cold/Flu", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Recovery details", required: false)
            ]
        case .surgeryProcedure, .surgeryCompleted:
            return [
                .init(key: "procedure", label: "Procedure", placeholder: "ACL reconstruction", required: true),
                .init(key: "provider", label: "Provider", placeholder: "Hospital or clinician", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Outcome or follow-up details", required: false)
            ]
        case .procedureCompleted:
            return [
                .init(key: "procedure", label: "Procedure", placeholder: "Endoscopy", required: true),
                .init(key: "provider", label: "Provider", placeholder: "Hospital or clinician", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Results", required: false)
            ]
        case .allergyAdded:
            return [
                .init(key: "allergen", label: "Allergen", placeholder: "Penicillin", required: true),
                .init(key: "severity", label: "Severity", placeholder: "Mild / Moderate / Severe", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Reaction details", required: false)
            ]
        case .allergyReaction:
            return [
                .init(key: "allergen", label: "Allergen", placeholder: "Peanuts", required: true),
                .init(key: "reaction", label: "Reaction", placeholder: "Hives, swelling", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Treatment taken", required: false)
            ]
        case .weightRecorded:
            return [
                .init(key: "weight", label: "Weight", placeholder: "165", required: true),
                .init(key: "unit", label: "Unit", placeholder: "lbs", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Context", required: false)
            ]
        case .heightRecorded:
            return [
                .init(key: "height", label: "Height", placeholder: "5'10\"", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Context", required: false)
            ]
        case .bloodPressureRecorded:
            return [
                .init(key: "systolic", label: "Systolic", placeholder: "120", required: true),
                .init(key: "diastolic", label: "Diastolic", placeholder: "80", required: true),
                .init(key: "notes", label: "Notes", placeholder: "Context", required: false)
            ]
        case .metricSnapshot:
            return [
                .init(key: "title", label: "Title", placeholder: "Weekly check-in", required: false),
                .init(key: "notes", label: "Notes", placeholder: "Health snapshot details", required: false)
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

struct TimelineEvent: Identifiable, Equatable {
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
        if eventType == .custom {
            let orderedKeys = ["title", "event", "name", "details"]
            for key in orderedKeys {
                if let value = data[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }
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

        let orderedKeys: [String]
        if eventType == .custom {
            orderedKeys = ["details", "notes", "event", "name", "title"]
        } else {
            orderedKeys = ["name", "condition", "injury", "procedure", "panel", "change", "event", "title", "notes"]
        }
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

// MARK: - TimelineEvent Codable (cross-platform: web uses Unix ms, iOS uses ISO8601)

extension TimelineEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, eventType, timestamp, data, metadata
        case anomalyType, metricType, direction, deviationPct
        case resolvedAt, attestationTxHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        eventType = try container.decode(TimelineEventType.self, forKey: .eventType)

        // Timestamp: try ISO8601 string first (iOS-stored), then Unix ms number (web-stored)
        if let dateValue = try? container.decode(Date.self, forKey: .timestamp) {
            timestamp = dateValue
        } else if let ms = try? container.decode(Double.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = try? container.decode(Int.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: Double(ms) / 1000)
        } else {
            timestamp = Date()
        }

        // Data: web sends Record<string, unknown>, coerce values to strings
        if let stringDict = try? container.decode([String: String].self, forKey: .data) {
            data = stringDict
        } else if let anyDict = try? container.decode([String: AnyCodableValue].self, forKey: .data) {
            data = anyDict.mapValues { $0.stringValue }
        } else {
            data = [:]
        }

        // Metadata: flexible — web has { source, confidence, tags }, iOS has { platform, version, source }
        metadata = (try? container.decode(TimelineEventMetadata.self, forKey: .metadata))
            ?? TimelineEventMetadata(platform: "unknown", version: "1", source: .userEntered)

        anomalyType = try container.decodeIfPresent(String.self, forKey: .anomalyType)
        metricType = try container.decodeIfPresent(String.self, forKey: .metricType)
        direction = try container.decodeIfPresent(String.self, forKey: .direction)
        deviationPct = try container.decodeIfPresent(Double.self, forKey: .deviationPct)
        attestationTxHash = try container.decodeIfPresent(String.self, forKey: .attestationTxHash)

        // resolvedAt: same timestamp flexibility as above
        if let dateValue = try? container.decodeIfPresent(Date.self, forKey: .resolvedAt) {
            resolvedAt = dateValue
        } else if let ms = try? container.decodeIfPresent(Double.self, forKey: .resolvedAt) {
            resolvedAt = Date(timeIntervalSince1970: ms / 1000)
        } else {
            resolvedAt = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(data, forKey: .data)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(anomalyType, forKey: .anomalyType)
        try container.encodeIfPresent(metricType, forKey: .metricType)
        try container.encodeIfPresent(direction, forKey: .direction)
        try container.encodeIfPresent(deviationPct, forKey: .deviationPct)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try container.encodeIfPresent(attestationTxHash, forKey: .attestationTxHash)
    }
}

/// Decode any JSON value and convert to string.
private enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return ""
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if container.decodeNil() { self = .null }
        else { self = .null }
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

    init(platform: String, version: String, source: TimelineEventSource) {
        self.platform = platform
        self.version = version
        self.source = source
    }

    /// Flexible decoding: web sends { source, confidence, tags }, iOS sends { platform, version, source }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        platform = (try? container.decode(String.self, forKey: .platform)) ?? "web"
        version = (try? container.decode(String.self, forKey: .version)) ?? "1"

        // Web sends source as "user-input" / "ai-extracted" / "imported" / "attested"
        // iOS sends "user" / "auto"
        if let sourceString = try? container.decode(String.self, forKey: .source) {
            source = TimelineEventSource(webValue: sourceString)
        } else {
            source = .userEntered
        }
    }

    private enum CodingKeys: String, CodingKey {
        case platform, version, source
    }
}

enum TimelineEventSource: String, Codable {
    case userEntered = "user"
    case autoDetected = "auto"

    /// Map web source strings to iOS enum values.
    init(webValue: String) {
        switch webValue {
        case "user", "user-input": self = .userEntered
        case "auto", "ai-extracted": self = .autoDetected
        default: self = .userEntered
        }
    }
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

extension String {
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
