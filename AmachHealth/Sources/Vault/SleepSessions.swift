// SleepSessions.swift
// AmachHealth
//
// Turns HealthKit sleep samples into nights, the way the Health app counts
// them, so "last night" matches Apple's Time Asleep:
//
// - Samples are grouped into sessions per source; a gap of more than two
//   hours between samples starts a new session.
// - When several sources recorded the same night (Watch, iPhone, a sleep
//   app), only one is counted: the one with sleep stages, then the one with
//   the most time asleep. Summing them would double count.
// - A whole session belongs to the day it ends. Stage samples that end
//   before midnight (falling asleep at 11pm) stay with the night they are
//   part of instead of being credited to the previous day.

import Foundation

struct SleepSample: Equatable {
    let start: Date
    let end: Date
    /// HKCategoryValueSleepAnalysis raw value: 0 in bed, 1 asleep (unspecified),
    /// 2 awake, 3 core, 4 deep, 5 REM.
    let value: Int
    /// Source bundle id (or name). Samples from different sources are never summed.
    let source: String

    var minutes: Double { end.timeIntervalSince(start) / 60 }
    var isAsleep: Bool { [1, 3, 4, 5].contains(value) }
    var isStage: Bool { [3, 4, 5].contains(value) }
}

struct SleepSession: Equatable {
    let source: String
    let samples: [SleepSample]
    /// Other sources that recorded this night and were not counted.
    var ignoredSources: [String] = []

    var start: Date { samples.map(\.start).min() ?? .distantPast }
    var end: Date { samples.map(\.end).max() ?? .distantPast }
    var day: String { end.vaultDay }

    private func minutes(_ values: Set<Int>) -> Double {
        samples.filter { values.contains($0.value) }.reduce(0) { $0 + $1.minutes }
    }
    var inBedMinutes: Double { minutes([0]) }
    var awakeMinutes: Double { minutes([2]) }
    var coreMinutes: Double { minutes([1, 3]) }   // unspecified asleep counts as core
    var deepMinutes: Double { minutes([4]) }
    var remMinutes: Double { minutes([5]) }
    var asleepMinutes: Double { coreMinutes + deepMinutes + remMinutes }
    var hasStages: Bool { samples.contains(where: \.isStage) }
}

enum SleepSessionBuilder {
    /// A longer break than this between samples starts a new session.
    static let sessionGap: TimeInterval = 2 * 3600

    static func sessions(_ samples: [SleepSample]) -> [SleepSession] {
        // 1. Sessions per source.
        var perSource: [SleepSession] = []
        for (source, items) in Dictionary(grouping: samples, by: \.source) {
            var current: [SleepSample] = []
            var currentEnd = Date.distantPast
            for sample in items.sorted(by: { $0.start < $1.start }) {
                if !current.isEmpty, sample.start.timeIntervalSince(currentEnd) > sessionGap {
                    perSource.append(SleepSession(source: source, samples: current))
                    current = []
                }
                current.append(sample)
                currentEnd = max(currentEnd, sample.end)
            }
            if !current.isEmpty { perSource.append(SleepSession(source: source, samples: current)) }
        }

        // 2. Cluster overlapping sessions from different sources into nights.
        var clusters: [[SleepSession]] = []
        for session in perSource.sorted(by: { $0.start < $1.start }) {
            if var last = clusters.last,
               let lastEnd = last.map(\.end).max(),
               session.start.timeIntervalSince(lastEnd) <= sessionGap {
                last.append(session)
                clusters[clusters.count - 1] = last
            } else {
                clusters.append([session])
            }
        }

        // 3. One source per night.
        return clusters.flatMap { cluster -> [SleepSession] in
            let bySource = Dictionary(grouping: cluster, by: \.source)
            guard bySource.count > 1 else { return cluster }
            let ranked = bySource.sorted { a, b in
                let aStages = a.value.contains(where: \.hasStages), bStages = b.value.contains(where: \.hasStages)
                if aStages != bStages { return aStages }
                let aAsleep = a.value.reduce(0) { $0 + $1.asleepMinutes }
                let bAsleep = b.value.reduce(0) { $0 + $1.asleepMinutes }
                if aAsleep != bAsleep { return aAsleep > bAsleep }
                return a.key < b.key
            }
            let ignored = ranked.dropFirst().map(\.key).sorted()
            return ranked[0].value.map { session in
                var kept = session
                kept.ignoredSources = ignored
                return kept
            }
        }
        .sorted { $0.start < $1.start }
    }

    /// The night that ends on `day` with the most time asleep (naps excluded).
    static func mainSession(endingOn day: String, in sessions: [SleepSession]) -> SleepSession? {
        sessions.filter { $0.day == day }.max { $0.asleepMinutes < $1.asleepMinutes }
    }
}
