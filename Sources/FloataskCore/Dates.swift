import Foundation

public enum Dates {
    /// ISO-8601 with local offset, e.g. 2026-09-29T15:30:00+06:00
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    public static func parseISO(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: t)
    }

    /// YYYY-MM-DD in the local calendar.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    public static func parseDay(_ s: String, calendar: Calendar = .current) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, s.count == 10 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        guard let d = calendar.date(from: c), dayKey(d, calendar: calendar) == s else { return nil }
        return d
    }

    public static func isValidDay(_ s: String) -> Bool { parseDay(s) != nil }

    /// "1h 45m", "25m", "40s"
    public static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return seconds <= 0 ? "0m" : "\(seconds)s" }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// "18:42"
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Human label for a due date relative to today: "Today", "Tomorrow", "Thu", "Oct 12", "2d overdue".
    public static func dueLabel(_ day: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let d = parseDay(day, calendar: calendar) else { return day }
        let today = calendar.startOfDay(for: now)
        let diff = calendar.dateComponents([.day], from: today, to: d).day ?? 0
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case ..<(-1): return "\(-diff)d overdue"
        case 2...6:
            let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: d)
        default:
            let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
        }
    }
}

/// Deterministic natural-language date extraction. Used as a backstop for the
/// (small, on-device) AI model, which is unreliable at weekday arithmetic.
public enum NaturalDate {
    public struct Match { public let day: String; public let range: Range<String.Index> }

    public static func find(in text: String, now: Date = Date(), calendar: Calendar = .current) -> Match? {
        let lower = text.lowercased()
        let today = calendar.startOfDay(for: now)
        func add(_ days: Int) -> String { Dates.dayKey(calendar.date(byAdding: .day, value: days, to: today)!, calendar: calendar) }

        // ISO date
        if let r = lower.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression),
           Dates.isValidDay(String(lower[r])) {
            return Match(day: String(lower[r]), range: r)
        }
        let fixed: [(String, Int)] = [
            (#"\bday after tomorrow\b"#, 2), (#"\btomorrow\b"#, 1), (#"\btmrw\b"#, 1),
            (#"\btoday\b"#, 0), (#"\btonight\b"#, 0), (#"\bthis evening\b"#, 0),
        ]
        for (pattern, days) in fixed {
            if let r = lower.range(of: pattern, options: .regularExpression) { return Match(day: add(days), range: r) }
        }
        // in N days / weeks
        if let r = lower.range(of: #"\bin (\d{1,2}) (day|days|week|weeks)\b"#, options: .regularExpression) {
            let words = lower[r].split(separator: " ")
            if let n = Int(words[1]) {
                return Match(day: add(words[2].hasPrefix("week") ? n * 7 : n), range: r)
            }
        }
        // next week → next Monday (or calendar's first weekday)
        if let r = lower.range(of: #"\bnext week\b"#, options: .regularExpression) {
            let wd = calendar.component(.weekday, from: today)
            var delta = (calendar.firstWeekday == 1 ? 2 : calendar.firstWeekday) - wd
            if delta <= 0 { delta += 7 }
            return Match(day: add(delta), range: r)
        }
        // weekday names, optionally prefixed with next/this/on/by/before/until
        let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let short = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        for (i, name) in names.enumerated() {
            let pattern = #"\b(next |this |on |by |before |until |till )?("# + name + "|" + short[i] + (i == 2 ? "|tues" : "") + (i == 4 ? "|thur|thurs" : "") + #")\b"#
            if let r = lower.range(of: pattern, options: .regularExpression) {
                let wd = calendar.component(.weekday, from: today) - 1   // 0 = Sunday
                var delta = i - wd
                if delta <= 0 { delta += 7 }
                return Match(day: add(delta), range: r)
            }
        }
        // "oct 3", "3 oct", "october 3rd"
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let monthPattern = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"#
        let patterns = [monthPattern + #" (\d{1,2})(st|nd|rd|th)?\b"#, #"\b(\d{1,2})(st|nd|rd|th)? "# + monthPattern]
        for p in patterns {
            if let r = lower.range(of: #"\b"# + p, options: .regularExpression) ?? lower.range(of: p, options: .regularExpression) {
                let chunk = String(lower[r])
                guard let mIdx = months.firstIndex(where: { chunk.contains($0) }),
                      let dr = chunk.range(of: #"\d{1,2}"#, options: .regularExpression),
                      let dayNum = Int(chunk[dr]) else { continue }
                let year = calendar.component(.year, from: today)
                for y in [year, year + 1] {
                    let key = String(format: "%04d-%02d-%02d", y, mIdx + 1, dayNum)
                    if let d = Dates.parseDay(key, calendar: calendar), d >= today {
                        return Match(day: key, range: r)
                    }
                }
            }
        }
        return nil
    }
}
