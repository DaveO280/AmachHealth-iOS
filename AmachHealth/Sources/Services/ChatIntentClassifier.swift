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
        "test results", "panel"
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

    /// Classify user message into a single intent. &lt;1ms, no API call.
    static func classify(_ message: String) -> ChatIntent {
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return .general }

        let words = Set(lower.split(separator: " ").map(String.init))
        func hasAny(_ keywords: [String]) -> Bool {
            keywords.contains { kw in
                lower.contains(kw) || words.contains(kw)
            }
        }

        if hasAny(sleepKeywords) { return .sleep }
        if hasAny(labsKeywords) { return .labs }
        if hasAny(medicationsKeywords) { return .medications }
        if hasAny(bodyCompKeywords) { return .bodyComp }
        if hasAny(activityKeywords) { return .activity }
        if hasAny(recoveryKeywords) { return .recovery }
        if hasAny(vitalsKeywords) { return .vitals }

        return .general
    }
}
