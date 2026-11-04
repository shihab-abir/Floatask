import Foundation

/// Sessions.md — an app-managed log of focus sessions, grouped by the local day they started.
///
///     ## 2026-09-29
///
///     - session_id: fs_20260929_153000
///       task_id: t_20260929_ab12
///       task: "Finish landing page"
///       started_at: 2026-09-29T15:30:00+06:00
///       ended_at: 2026-09-29T15:55:04+06:00
///       planned_minutes: 25
///       actual_seconds: 1500
///       status: completed
///
/// Values may be edited by hand; the file is rewritten deterministically on every change.
public enum SessionsDocument {
    static let itemStart = try! NSRegularExpression(pattern: #"^- ([a-z_]+):\s?(.*)$"#)
    static let itemCont = try! NSRegularExpression(pattern: #"^[ \t]+([a-z_]+):\s?(.*)$"#)

    public struct ParseResult {
        public var sessions: [FocusSession]
        public var skipped: Int      // items that could not be understood (kept out, reported)
    }

    public static func parse(_ text: String) -> ParseResult {
        var items: [[(String, String)]] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = itemStart.firstMatch(in: line, range: range) {
                items.append([(ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))])
            } else if let m = itemCont.firstMatch(in: line, range: range), !items.isEmpty {
                items[items.count - 1].append((ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))))
            }
        }
        var sessions: [FocusSession] = []
        var skipped = 0
        for fields in items {
            if let s = session(from: fields) { sessions.append(s) } else { skipped += 1 }
        }
        return ParseResult(sessions: sessions, skipped: skipped)
    }

    static func session(from fields: [(String, String)]) -> FocusSession? {
        var d: [String: String] = [:]
        var extra: [(String, String)] = []
        let known: Set<String> = ["session_id", "task_id", "task", "started_at", "ended_at", "planned_minutes",
                                  "actual_seconds", "status", "paused_seconds", "paused_at", "note"]
        for (k, v) in fields {
            let value = unquote(v)
            if known.contains(k) { d[k] = value } else { extra.append((k, v)) }
        }
        guard let id = d["session_id"], !id.isEmpty,
              let started = d["started_at"].flatMap(Dates.parseISO),
              let status = d["status"].flatMap(SessionStatus.init(rawValue:)) else { return nil }
        var s = FocusSession(
            id: id,
            taskId: d["task_id"].flatMap { $0.isEmpty ? nil : $0 },
            taskTitle: d["task"] ?? "",
            startedAt: started,
            endedAt: d["ended_at"].flatMap(Dates.parseISO),
            plannedMinutes: Int(d["planned_minutes"] ?? "") ?? 25,
            actualSeconds: Int(d["actual_seconds"] ?? "") ?? 0,
            status: status,
            pausedSeconds: Int(d["paused_seconds"] ?? "") ?? 0,
            pausedAt: d["paused_at"].flatMap(Dates.parseISO),
            note: d["note"].flatMap { $0.isEmpty ? nil : $0 })
        s.extra = extra
        return s
    }

    public static func serialize(_ sessions: [FocusSession]) -> String {
        var out = ["---", "schema_version: 1", "type: task_manager_sessions", "---", "", "# Focus Sessions", ""]
        out.append("_Managed by Floatask. Values can be edited; keep one `- session_id:` item per session._")
        let sorted = sessions.sorted { $0.startedAt > $1.startedAt }
        var currentDay: String?
        for s in sorted {
            let day = Dates.dayKey(s.startedAt)
            if day != currentDay {
                out += ["", "## \(day)", ""]
                currentDay = day
            } else {
                out.append("")
            }
            out.append("- session_id: \(s.id)")
            out.append("  task_id: \(s.taskId ?? "")")
            out.append("  task: \(quote(s.taskTitle))")
            out.append("  started_at: \(Dates.iso(s.startedAt))")
            out.append("  ended_at: \(s.endedAt.map(Dates.iso) ?? "")")
            out.append("  planned_minutes: \(s.plannedMinutes)")
            out.append("  actual_seconds: \(s.actualSeconds)")
            out.append("  status: \(s.status.rawValue)")
            if s.pausedSeconds > 0 || s.status.isActive { out.append("  paused_seconds: \(s.pausedSeconds)") }
            if let p = s.pausedAt { out.append("  paused_at: \(Dates.iso(p))") }
            if let n = s.note { out.append("  note: \(quote(n))") }
            for (k, v) in s.extra { out.append("  \(k): \(v)") }
        }
        return out.joined(separator: "\n") + "\n"
    }

    static func quote(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let json = String(data: data, encoding: .utf8)!   // ["..."]
        return String(json.dropFirst().dropLast())
    }

    static func unquote(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2,
           let data = "[\(v)]".data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String], let s = arr.first {
            return s
        }
        if v.hasPrefix("'"), v.hasSuffix("'"), v.count >= 2 { return String(v.dropFirst().dropLast()) }
        return v
    }
}
