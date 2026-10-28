// ChatIntentClassifier.swift
// AmachHealth
//
// On-device keyword classifier for Luma context routing.
// Classifies each message into one of 8 intents and exposes correlated
// metric keys so the context builder can send only relevant data.

import Foundation

// MARK: - Chat Mode (backend quick/deep)

enum ChatMode: String, Codable, CaseIterable {
    case quick
    case deep
}

// MARK: - Chat Intent

enum ChatIntent: String, CaseIterable {
    case sleep
    case activity
    case recovery
    case vitals
    case labs
    case medications
    case bodyComp
    case general
}

// MARK: - Correlated metric keys per intent

extension ChatIntent {
    /// Metric keys to include in context for this intent (quick mode).
    var metricKeys: Set<String> {
        switch self {
        case .sleep:
            return ["sleep", "hrv", "restingHeartRate", "sleepDeepHours", "sleepRemHours"]
        case .activity:
            return ["steps", "exercise", "heartRate"]
        case .recovery:
            return ["hrv", "restingHeartRate", "sleep", "recoveryScore", "sleepDeepHours", "sleepRemHours"]
        case .vitals:
            return ["heartRate", "restingHeartRate", "hrv", "respiratoryRate", "vo2Max"]
        case .labs:
            return ["steps", "heartRate", "hrv", "sleep", "restingHeartRate", "vo2Max"]
        case .medications:
            return [] // timeline/conditions only
        case .bodyComp:
            return ["steps", "heartRate", "sleep", "exercise"]
        case .general:
            return ["steps", "heartRate", "hrv", "sleep", "exercise", "restingHeartRate", "vo2Max", "respiratoryRate", "recoveryScore", "sleepDeepHours", "sleepRemHours"]
        }
    }

    var includesLabData: Bool {
        switch self {
        case .labs, .bodyComp, .general: return true
        default: return false
        }
    }

    var includesTimelineEvents: Bool {
        switch self {
        case .medications, .labs, .general: return true
        default: return false
        }
    }

    var includesAnomalies: Bool {
        switch self {
        case .sleep, .recovery, .vitals, .general: return true
        default: return false
        }
    }

    var includesHRZones: Bool {
        switch self {
        case .activity, .recovery, .general: return true
        default: return false
        }
    }

    var includesWorkouts: Bool {
        switch self {
        case .activity, .recovery, .general: return true
        default: return false
        }
    }
}

// MARK: - Classifier

enum ChatIntentClassifier {
    private static let sleepKeywords = [
        "sleep", "slept", "sleeping", "insomnia", "rested", "tired",
        "wake", "waking", "bedtime", "night", "last night", "last night's",
        "deep sleep", "rem", "stages", "efficiency", "quality"
    ]

    private static let activityKeywords = [
        "steps", "walk", "running", "run", "exercise", "workout", "training",
        "active", "activity", "move", "calories", "burned", "zone 2", "zone 3",
        "cardio", "aerobic", "minutes"
    ]

    private static let recoveryKeywords = [
        "recovery", "recovered", "hrv", "resting heart rate", "rhr",
        "rest day", "overtraining", "fatigue", "stress", "rest"
    ]

    private static let vitalsKeywords = [
        "heart rate", "heartrate", "bpm", "blood pressure", "bp",
        "respiratory", "breathing", "vo2", "vo2max", "fitness",
        "oxygen", "spo2"
    ]

    private static let labsKeywords = [
        "lab", "labs", "blood", "bloodwork", "cholesterol", "glucose",
        "a1c", "hba1c", "lipid", "triglyceride", "hdl", "ldl",
        "tsh", "thyroid", "vitamin d", "ferritin", "draw", "results",
        "test results", "panel", "gut", "microbiome", "microbes", "bacteria", "probiotic"
    ]

    private static let medicationsKeywords = [
        "medication", "medications", "meds", "taking", "prescription",
        "supplement", "supplements", "drug", "dose", "mg",
        "allergy", "allergies", "condition", "conditions"
    ]

    private static let bodyCompKeywords = [
        "dexa", "body fat", "body composition", "lean mass", "bone",
        "visceral", "android", "gynoid", "scan", "inbody"
    ]

    /// Intents in priority order, used to break ties.
    private static let ordered: [(ChatIntent, [String])] = [
        (.sleep, sleepKeywords), (.labs, labsKeywords), (.medications, medicationsKeywords),
        (.bodyComp, bodyCompKeywords), (.activity, activityKeywords), (.recovery, recoveryKeywords),
        (.vitals, vitalsKeywords)
    ]

    /// Whole-word matches, allowing plurals and -ed/-ing ("workouts", "slept"
    /// is its own keyword), so "rest" doesn't match "interest" or "rem" "remember".
    private static func hits(_ keywords: [String], in text: String) -> Int {
        keywords.reduce(0) { count, kw in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: kw) + "(?:s|es|ed|ing)?\\b"
            return count + (text.range(of: pattern, options: .regularExpression) != nil ? 1 : 0)
        }
    }

    /// Words that point at the user's timeline: a change over time, an
    /// illness or injury, a procedure.
    private static let timelineKeywords = [
        "since", "start", "started", "stopped", "began", "begin", "quit", "timeline", "history",
        "sick", "ill", "illness", "flu", "cold", "covid", "infection", "virus", "symptom",
        "injury", "injured", "hurt", "pain", "sprain", "strain", "surgery", "procedure", "operation",
        "diagnosed", "diagnosis", "diet", "fasting", "stress", "stressed", "travel", "lifestyle"
    ]

    private static let topicWords = Set(ordered.flatMap(\.1))

    /// Words in logged names too common to mean the user is naming that item.
    private static let nameStopwords: Set<String> = [
        "right", "left", "daily", "chronic", "acute", "severe", "moderate", "minor", "other"
    ]

    /// Whether the message is about something on the timeline: a timeline
    /// word, or a word (5+ letters) from something the user logged by name,
    /// such as "magnesium" from "Magnesium Glycinate". Topic words ("sleep"
    /// in "Sleep Apnea") don't count: the intents already route those.
    static func mentionsTimeline(_ message: String, names: [String] = []) -> Bool {
        let lower = message.lowercased()
        if hits(timelineKeywords, in: lower) > 0 { return true }
        let words = Set(names.flatMap { $0.lowercased().components(separatedBy: CharacterSet.letters.inverted) })
            .filter { $0.count >= 5 && !nameStopwords.contains($0) && !topicWords.contains($0) }
        return hits(Array(words), in: lower) > 0
    }

    /// Every intent the message touches, strongest first. `.general` when none.
    static func classifyAll(_ message: String) -> [ChatIntent] {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return [.general] }
        let scored = ordered.enumerated()
            .map { (index: $0.offset, intent: $0.element.0, hits: hits($0.element.1, in: lower)) }
            .filter { $0.hits > 0 }
            .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.index < $1.index }
        return scored.isEmpty ? [.general] : scored.map(\.intent)
    }

    /// The strongest intent in the message. &lt;1ms, no API call.
    static func classify(_ message: String) -> ChatIntent {
        classifyAll(message)[0]
    }
}
