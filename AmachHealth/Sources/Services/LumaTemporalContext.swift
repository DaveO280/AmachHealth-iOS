// LumaTemporalContext.swift
// AmachHealth
//
// Time for Luma's context:
//   • LumaDate: every dated record carries its age ("5 months ago"), so the
//     model never has to estimate how old a lab report is.
//   • LumaPeriodResolver: finds a period the user names ("in March",
//     "last summer", "3 months ago", "2025") in their message.
//   • LumaHistoryBuilder: the vault's long daily history as monthly and
//     yearly averages, and day/week/month values for a named period.

import Foundation

// MARK: - Dates and ages

enum LumaDate {

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// Formats report dates arrive in. US order for slashed dates.
    private static let formats = [
        "MM/dd/yyyy", "M/d/yyyy", "yyyy/MM/dd", "dd.MM.yyyy",
        "MMM d, yyyy", "MMMM d, yyyy", "MMM d yyyy", "MMMM d yyyy", "d MMM yyyy", "d MMMM yyyy",
        "MMM yyyy", "MMMM yyyy", "yyyy-MM"
    ]

    /// Parses a report date. ISO dates and timestamps use their `YYYY-MM-DD` part.
    static func parse(_ raw: String?, calendar: Calendar = .current) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            return formatter("yyyy-MM-dd", calendar: calendar).date(from: String(raw.prefix(10)))
        }
        // "5/14/26": a two-digit year, which "M/d/yyyy" would read as year 26.
        if raw.range(of: #"^\d{1,2}/\d{1,2}/\d{2}$"#, options: .regularExpression) != nil {
            return formatter("M/d/yy", calendar: calendar).date(from: raw)
        }
        let cleaned = raw.replacingOccurrences(of: #"(\d)(st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)
        for format in formats {
            if let date = formatter(format, calendar: calendar).date(from: cleaned) { return date }
        }
        return nil
    }

    /// `YYYY-MM-DD`.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("yyyy-MM-dd", calendar: calendar).string(from: date)
    }

    /// A report date as `YYYY-MM-DD` when it parses, otherwise as written.
    static func normalizedDay(_ raw: String?, calendar: Calendar = .current) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return parse(raw, calendar: calendar).map { day($0, calendar: calendar) } ?? raw
    }

    /// "today", "3 days ago", "5 weeks ago", "7 months ago", "2 years ago".
    static func age(of date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = calendar.startOfDay(for: date), end = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        if days < 0 { return days == -1 ? "tomorrow" : "in \(-days) days" }
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 14 { return "\(days) days ago" }
        if days < 60 { return "\(days / 7) weeks ago" }
        let months = max(2, calendar.dateComponents([.month], from: start, to: end).month ?? 0)
        if months < 24 { return "\(months) months ago" }
        return "\(months / 12) years ago"
    }

    /// "2026-05-14, 5 months ago"; an unparseable date is returned as written.
    static func stamp(_ raw: String?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let date = parse(raw, calendar: calendar) else { return "\(raw), age unknown" }
        return "\(day(date, calendar: calendar)), \(age(of: date, now: now, calendar: calendar))"
    }

    /// When a report is from: its own date, or, without one, when it was added.
    static func reportWhen(
        _ raw: String?, verb: String, uploadedAt: Date?, now: Date = Date(), calendar: Calendar = .current
    ) -> String {
        if let s = stamp(raw, now: now, calendar: calendar) { return "\(verb) \(s)" }
        if let uploadedAt {
            return "\(verb) date not on the report; added to the app \(day(uploadedAt, calendar: calendar)), "
                + age(of: uploadedAt, now: now, calendar: calendar)
        }
        return "date unknown"
    }

    /// The date a report sorts by: its own date, else when it was added.
    static func sortDate(_ raw: String?, uploadedAt: Date?, calendar: Calendar = .current) -> Date {
        parse(raw, calendar: calendar) ?? uploadedAt ?? .distantPast
    }
}

// MARK: - Periods named in a message

enum LumaPeriodResolver {

    struct Period: Equatable {
        let start: Date
        /// Last day included.
        let end: Date
        let label: String
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july",
                                 "august", "september", "october", "november", "december"]
    private static let monthPattern =
        "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"

    private static func monthIndex(_ token: String) -> Int? {
        months.firstIndex { $0.hasPrefix(String(token.prefix(3))) }.map { $0 + 1 }
    }

    private static func numberValue(_ token: String) -> Int? {
        let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                     "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "couple of": 2, "few": 3]
        return Int(token) ?? words[token]
    }

    /// Up to two periods named in the message, in the order they appear.
    /// Today, yesterday and last night are left out: recent days are always in context.
    static func resolve(_ message: String, now: Date = Date(), calendar: Calendar = .current) -> [Period] {
        let text = message.lowercased()
        let today = calendar.startOfDay(for: now)
        var found: [(position: Int, period: Period)] = []

        func matches(_ pattern: String) -> [[String?]] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
                (0..<m.numberOfRanges).map { i in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                } + [String(m.range.location)]
            }
        }
        func add(_ groups: [String?], _ period: Period?) {
            guard let period, let last = groups.last, let pos = last.flatMap({ Int($0) }) else { return }
            // Never reach past today.
            let end = min(period.end, today)
            guard period.start <= end else { return }
            found.append((pos, Period(start: period.start, end: end, label: period.label)))
        }
        func date(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            calendar.date(from: DateComponents(year: y, month: m, day: d))
        }
        func monthPeriod(_ y: Int, _ m: Int, label: String? = nil) -> Period? {
            guard let start = date(y, m, 1),
                  let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) else { return nil }
            return Period(start: start, end: end, label: label ?? "\(months[m - 1].capitalized) \(y)")
        }
        /// The most recent month with this number that has started.
        func recentYear(for month: Int) -> Int {
            let current = calendar.component(.month, from: now), year = calendar.component(.year, from: now)
            return month <= current ? year : year - 1
        }
        func around(_ day: Date, label: String) -> Period? {
            guard let s = calendar.date(byAdding: .day, value: -3, to: day),
                  let e = calendar.date(byAdding: .day, value: 3, to: day) else { return nil }
            return Period(start: s, end: e, label: label)
        }
        let year = calendar.component(.year, from: now)
        let units: [String: Calendar.Component] = ["day": .day, "week": .weekOfYear, "month": .month, "year": .year]

        // Specific days: 2026-03-14, March 14(th)(, 2025), 14(th) (of) March (2025)
        for g in matches(#"\b(\d{4})-(\d{2})-(\d{2})\b"#) {
            if let y = Int(g[1]!), let m = Int(g[2]!), let d = Int(g[3]!), let day = date(y, m, d) {
                add(g, around(day, label: "around \(LumaDate.day(day, calendar: calendar))"))
            }
        }
        for g in matches("\\b\(monthPattern)\\.? (\\d{1,2})(?:st|nd|rd|th)?\\b(?:,? (\\d{4}))?") {
            guard let m = monthIndex(g[1]!), let d = Int(g[2]!), d <= 31 else { continue }
            let y = g[3].flatMap { Int($0) } ?? recentYear(for: m)
            if let day = date(y, m, d) { add(g, around(day, label: "around \(LumaDate.day(day, calendar: calendar))")) }
        }
        for g in matches("\\b(\\d{1,2})(?:st|nd|rd|th)? (?:of )?\(monthPattern)\\b(?: (\\d{4}))?") {
            guard let d = Int(g[1]!), d <= 31, let m = monthIndex(g[2]!) else { continue }
            let y = g[3].flatMap { Int($0) } ?? recentYear(for: m)
            if let day = date(y, m, d) { add(g, around(day, label: "around \(LumaDate.day(day, calendar: calendar))")) }
        }

        // Month and year: "March 2025"
        for g in matches("\\b\(monthPattern) (\\d{4})\\b") {
            if let m = monthIndex(g[1]!), let y = Int(g[2]!) { add(g, monthPeriod(y, m)) }
        }
        // A month after a preposition, so "may" and "march" as words don't count:
        // "in March", "since May", "last June"
        for g in matches("\\b(in|during|since|from|of|through|until|over|early|late|mid|last|this past) \(monthPattern)\\b(?! \\d)") {
            guard let m = monthIndex(g[2]!) else { continue }
            var y = recentYear(for: m)
            if g[1] == "last", m == calendar.component(.month, from: now) { y -= 1 }
            if g[1] == "since", let start = date(y, m, 1) {
                add(g, Period(start: start, end: today, label: "since \(months[m - 1].capitalized) \(y)"))
            } else {
                add(g, monthPeriod(y, m))
            }
        }

        // Relative calendar periods
        for g in matches(#"\b(last|this|past|previous) (week|month|year)\b"#) {
            let unit = g[2]!
            let isLast = g[1] != "this"
            let component: Calendar.Component = unit == "week" ? .weekOfYear : unit == "month" ? .month : .year
            guard let thisStart = calendar.dateInterval(of: component, for: today)?.start else { continue }
            if isLast, let start = calendar.date(byAdding: component, value: -1, to: thisStart),
               let end = calendar.date(byAdding: .day, value: -1, to: thisStart) {
                add(g, Period(start: start, end: end, label: "last \(unit) (\(LumaDate.day(start, calendar: calendar)) to \(LumaDate.day(end, calendar: calendar)))"))
            } else if !isLast {
                add(g, Period(start: thisStart, end: today, label: "this \(unit) so far"))
            }
        }
        // "past 3 months", "last 6 weeks", "over the last two years"
        for g in matches(#"\b(?:past|last|previous) (\d+|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|couple of|few) (day|week|month|year)s?\b"#) {
            guard let n = numberValue(g[1]!), n > 0 else { continue }
            guard let component = units[g[2]!] else { continue }
            if let start = calendar.date(byAdding: component, value: -n, to: today) {
                add(g, Period(start: start, end: today, label: "the past \(n) \(g[2]!)\(n == 1 ? "" : "s")"))
            }
        }
        // "3 months ago", "a year ago", "two weeks ago"
        for g in matches(#"\b(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|couple of|few) (day|week|month|year)s? ago\b"#) {
            guard let n = numberValue(g[1]!), n > 0 else { continue }
            let unit = g[2]!
            guard let component = units[unit] else { continue }
            guard let point = calendar.date(byAdding: component, value: -n, to: today) else { continue }
            let label = "\(n) \(unit)\(n == 1 ? "" : "s") ago"
            if unit == "day" {
                add(g, around(point, label: label))
            } else if let interval = calendar.dateInterval(of: component, for: point),
                      let end = calendar.date(byAdding: .day, value: -1, to: interval.end) {
                add(g, Period(start: interval.start, end: end, label: label))
            }
        }
        // Seasons (northern hemisphere): "last summer", "this winter", "in the spring"
        let seasons: [String: (start: Int, months: Int)] = ["spring": (3, 3), "summer": (6, 3), "fall": (9, 3), "autumn": (9, 3), "winter": (12, 3)]
        for g in matches(#"\b(last|this|in the|over the|during the|this past) (spring|summer|fall|autumn|winter)\b"#) {
            guard let season = seasons[g[2]!] else { continue }
            var y = year
            if let start = date(y, season.start, 1), start > today { y -= 1 }
            if g[1] == "last", let start = date(y, season.start, 1),
               let end = calendar.date(byAdding: DateComponents(month: season.months, day: -1), to: start), end >= today { y -= 1 }
            guard let start = date(y, season.start, 1),
                  let end = calendar.date(byAdding: DateComponents(month: season.months, day: -1), to: start) else { continue }
            add(g, Period(start: start, end: end, label: "\(g[2]!) \(y)\(season.start == 12 ? "–\(String(y + 1).suffix(2))" : "")"))
        }
        // Years: "in 2025", "since 2024", "my 2025 bloodwork"
        for g in matches(#"\b(since |from |in |during |for |of |my |the |back in |early |late |mid |throughout )((?:19|20)\d{2})\b"#) {
            guard let y = Int(g[2]!), y <= year, y >= year - 30, let start = date(y, 1, 1) else { continue }
            if g[1] == "since " || g[1] == "from " {
                add(g, Period(start: start, end: today, label: "since \(y)"))
            } else if let end = date(y, 12, 31) {
                add(g, Period(start: start, end: end, label: "\(y)"))
            }
        }

        // First mention wins where matches overlap (e.g. "March 2025" also matches "2025").
        var periods: [Period] = []
        var usedPositions: [Int] = []
        for item in found.sorted(by: { $0.position < $1.position }) {
            if usedPositions.contains(where: { abs($0 - item.position) < 12 }) { continue }
            if periods.contains(item.period) { continue }
            usedPositions.append(item.position)
            periods.append(item.period)
            if periods.count == 2 { break }
        }
        return periods
    }
}

// MARK: - Long-term history from the vault

struct LumaHistoryBuilder {
    let vault: VaultDatabase
    var now: Date = Date()
    var calendar: Calendar = .current

    struct Series {
        let metric: String
        let label: String
        let format: String
        /// SQL value expression; nil uses the metric's primary value.
        var column: String? = nil
        /// Multiplier applied to stored values (minutes → hours).
        var scale: Double = 1
        /// Intent metric keys (ChatIntent.metricKeys) this series answers.
        let keys: Set<String>
    }

    static let series: [Series] = [
        Series(metric: "steps", label: "Steps/day", format: "%.0f", keys: ["steps"]),
        Series(metric: AmachMetric.sleepId, label: "Sleep, h/night", format: "%.1f", scale: 1.0 / 60, keys: ["sleep"]),
        Series(metric: AmachMetric.sleepId, label: "Deep sleep, h", format: "%.2f", column: "sleep_deep_min", scale: 1.0 / 60, keys: ["sleepDeepHours"]),
        Series(metric: AmachMetric.sleepId, label: "REM sleep, h", format: "%.2f", column: "sleep_rem_min", scale: 1.0 / 60, keys: ["sleepRemHours"]),
        Series(metric: "hrv_sdnn", label: "HRV, ms", format: "%.0f", keys: ["hrv"]),
        Series(metric: "resting_heart_rate", label: "Resting HR, bpm", format: "%.0f", keys: ["restingHeartRate"]),
        Series(metric: "heart_rate", label: "Avg HR, bpm", format: "%.0f", keys: ["heartRate"]),
        Series(metric: "exercise_minutes", label: "Exercise, min/day", format: "%.0f", keys: ["exercise"]),
        Series(metric: AmachMetric.workoutMinutesId, label: "Workouts, min/day", format: "%.0f", keys: ["exercise"]),
        Series(metric: "active_energy", label: "Active energy, kcal/day", format: "%.0f", keys: ["exercise", "steps"]),
        Series(metric: "vo2_max", label: "VO2 max", format: "%.1f", keys: ["vo2Max"]),
        Series(metric: "respiratory_rate", label: "Respiratory rate", format: "%.1f", keys: ["respiratoryRate"]),
        Series(metric: "body_mass", label: "Weight, kg", format: "%.1f", keys: ["body"]),
        Series(metric: "body_fat", label: "Body fat, %", format: "%.1f", keys: ["body"]),
        Series(metric: "lean_body_mass", label: "Lean mass, kg", format: "%.1f", keys: ["body"]),
    ]

    /// Series for these intent keys; nil means all.
    static func series(for keys: Set<String>?) -> [Series] {
        guard let keys else { return series }
        return series.filter { !$0.keys.isDisjoint(with: keys) }
    }

    private var yesterday: Date {
        calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) ?? now
    }

    private func value(_ s: Series, _ v: Double) -> String { String(format: s.format, v * s.scale) }

    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private func monthLabel(_ ym: String) -> String {
        let parts = ym.split(separator: "-")
        guard parts.count == 2, let m = Int(parts[1]), (1...12).contains(m) else { return ym }
        return "\(Self.monthNames[m - 1]) \(parts[0])"
    }

    /// Monthly averages for the last 12 months plus this month so far, and yearly
    /// averages before that, for completed days. Nil when the vault has no history.
    func monthlyHistory(keys: Set<String>?) -> String? {
        guard let range = try? vault.dailyMetricDayRange() else { return nil }
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        guard let windowStart = calendar.date(byAdding: .month, value: -12, to: thisMonth) else { return nil }
        let windowStartDay = LumaDate.day(windowStart, calendar: calendar)
        let endDay = LumaDate.day(yesterday, calendar: calendar)
        let currentMonth = String(LumaDate.day(now, calendar: calendar).prefix(7))
        let beforeWindow = LumaDate.day(calendar.date(byAdding: .day, value: -1, to: windowStart) ?? windowStart, calendar: calendar)
        let windowStartYear = String(windowStartDay.prefix(4))
        let windowStartMonth = calendar.component(.month, from: windowStart)

        var lines: [String] = []
        for s in Self.series(for: keys) {
            let monthly = (try? vault.periodAverages(metric: s.metric, column: s.column, grouping: .month,
                                                     from: windowStartDay, through: endDay)) ?? []
            let yearly = (try? vault.periodAverages(metric: s.metric, column: s.column, grouping: .year,
                                                    from: range.first, through: beforeWindow)) ?? []
            guard !monthly.isEmpty || !yearly.isEmpty else { continue }
            var line = "- \(s.label):"
            if !yearly.isEmpty {
                line += " by year " + yearly.map { y in
                    let label = y.period == windowStartYear && windowStartMonth > 1
                        ? "\(y.period) (Jan–\(Self.monthNames[windowStartMonth - 2]))" : y.period
                    return "\(label) \(value(s, y.value))"
                }.joined(separator: ", ") + ";"
            }
            if !monthly.isEmpty {
                line += " by month " + monthly.map { m in
                    var out = monthLabel(m.period) + (m.period == currentMonth ? "*" : "") + " " + value(s, m.value)
                    if m.days < 7 { out += " (\(m.days)d)" }
                    return out
                }.joined(separator: ", ")
            }
            lines.append(line)
        }
        guard !lines.isEmpty else { return nil }
        let header = "Long-term wearable history (averages of days with data, oldest first; * = this month so far, "
            + "(Nd) = only N days of data). Vault data runs \(range.first) to \(range.last):"
        return ([header] + lines).joined(separator: "\n")
    }

    /// Values for a named period: daily up to 45 days, weekly up to ~6 months,
    /// monthly beyond. Says so when the vault has nothing for the period.
    func periodDetail(_ period: LumaPeriodResolver.Period, keys: Set<String>?) -> String {
        let startDay = LumaDate.day(period.start, calendar: calendar)
        let endDay = LumaDate.day(period.end, calendar: calendar)
        let days = (calendar.dateComponents([.day], from: period.start, to: period.end).day ?? 0) + 1
        let header = "Wearable data for \(period.label): \(startDay) to \(endDay) "
            + "(\(LumaDate.age(of: period.end, now: now, calendar: calendar)) at its end)"
        let dayFormat = DateFormatter()
        dayFormat.calendar = calendar
        dayFormat.timeZone = calendar.timeZone
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "MMM d"

        var lines: [String] = []
        for s in Self.series(for: keys) {
            let rows = ((try? vault.dailyMetrics(metric: s.metric, from: startDay, through: endDay)) ?? [])
                .compactMap { row -> (Date, Double)? in
                    let raw: Double?
                    switch s.column {
                    case "sleep_deep_min": raw = row.sleepDeepMin
                    case "sleep_rem_min": raw = row.sleepRemMin
                    default: raw = row.primaryValue
                    }
                    guard let v = raw, v > 0, let d = VaultDay.date(row.day) else { return nil }
                    return (d, v)
                }
            guard !rows.isEmpty else { continue }
            let mean = rows.map(\.1).reduce(0, +) / Double(rows.count)
            var line = "- \(s.label): avg \(value(s, mean)) over \(rows.count) day\(rows.count == 1 ? "" : "s")"
            if days <= 45 {
                line += "; " + rows.map { "\(dayFormat.string(from: $0.0)) \(value(s, $0.1))" }.joined(separator: ", ")
            } else if days <= 200 {
                var weeks: [(Date, [Double])] = []
                for (d, v) in rows {
                    let start = calendar.dateInterval(of: .weekOfYear, for: d)?.start ?? d
                    if let i = weeks.firstIndex(where: { $0.0 == start }) { weeks[i].1.append(v) }
                    else { weeks.append((start, [v])) }
                }
                line += "; weekly: " + weeks.map { w in
                    "wk of \(dayFormat.string(from: w.0)) \(value(s, w.1.reduce(0, +) / Double(w.1.count)))"
                }.joined(separator: ", ")
            } else {
                let monthly = (try? vault.periodAverages(metric: s.metric, column: s.column, grouping: .month,
                                                         from: startDay, through: endDay)) ?? []
                line += "; monthly: " + monthly.map { "\(monthLabel($0.period)) \(value(s, $0.value))" }.joined(separator: ", ")
            }
            lines.append(line)
        }
        if lines.isEmpty {
            return header + ":\n- No wearable data in the vault for this period. Don't estimate values for it."
        }
        return ([header + ":"] + lines).joined(separator: "\n")
    }
}
