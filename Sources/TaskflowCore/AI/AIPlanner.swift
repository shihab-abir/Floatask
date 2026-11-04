import Foundation

/// A validated operation the assistant wants to perform. Only these can ever touch the vault,
/// and only through `TaskService` — the model never writes files or runs commands.
public enum AIOperation: Equatable {
    case createTask(title: String, due: String?, priority: Priority?, group: String?, parentId: String?)
    case createSubtasks(parentId: String, titles: [String])
    case completeTask(id: String)
    case reopenTask(id: String)
    case updateTask(id: String, title: String?, due: String??, priority: Priority??, group: String??)
    case deleteTask(id: String)
    case startFocus(id: String, minutes: Int?)

    public var isDestructive: Bool { if case .deleteTask = self { return true } else { return false } }
}

public struct AIPlan {
    public var reply: String
    public var operations: [AIOperation]
    public var rejected: [String]       // operations dropped by validation (for transparency)
    public var providerName: String
    public var isLocal: Bool
}

/// Builds the prompt, calls the provider, and turns the answer into validated operations.
public struct AIPlanner {
    public let provider: AIProvider

    public init(provider: AIProvider) { self.provider = provider }

    public func plan(_ request: String, snapshot: Snapshot, now: Date = Date()) async throws -> AIPlan {
        let index = TaskIndex(snapshot: snapshot, now: now)
        let raw = try await provider.complete(system: AIPlanner.system, prompt: index.prompt(for: request, snapshot: snapshot, now: now))
        return try AIPlanner.parse(raw, request: request, index: index, snapshot: snapshot, now: now,
                                   providerName: provider.displayName, isLocal: provider.isLocal)
    }

    static let system = """
        You are the assistant inside Taskflow, a small to-do app. Turn the user's request into operations on \
        their task list. Respond with ONLY one JSON object and nothing else:
        {"reply": "one or two short, friendly sentences for the user", "operations": [ ... ]}

        Allowed operations (use task numbers exactly as listed; never invent numbers):
        {"op": "create_task", "title": "...", "due": "YYYY-MM-DD" or null, "priority": "high"|"medium"|"low"|null, "group": "existing group" or null, "parent": number or null}
        {"op": "create_subtasks", "parent": number, "titles": ["...", "..."]}
        {"op": "complete_task", "task": number}
        {"op": "reopen_task", "task": number}
        {"op": "update_task", "task": number, "title": "...", "due": "YYYY-MM-DD" or null, "priority": "...", "group": "..."}
        {"op": "delete_task", "task": number}
        {"op": "start_focus", "task": number, "minutes": number}

        Rules:
        - Titles are short and start with a verb. Do not put dates, "remind me to", or priority words in titles.
        - Resolve weekdays and relative dates with the calendar given in the request.
        - Only set priority if the user states it.
        - In update_task include only the fields that change.
        - To break a task down, use create_subtasks with 3 to 7 concrete steps.
        - For questions, summaries or suggestions, answer in "reply" and return an empty operations list.
        - When suggesting what to work on, prefer overdue, due-soon and high-priority tasks, and say why briefly.
        - Never claim you changed something unless the matching operation is in the list.

        Examples:
        User: "Add call the printer tomorrow" → {"reply": "Added it for tomorrow.", "operations": [{"op": "create_task", "title": "Call the printer", "due": "<tomorrow's date>", "priority": null, "group": null, "parent": null}]}
        User: "Delete the hero section task" (task [5]) → {"reply": "I'll delete it.", "operations": [{"op": "delete_task", "task": 5}]}
        User: "Move task 2 to Friday" → {"reply": "Moved to Friday.", "operations": [{"op": "update_task", "task": 2, "due": "<Friday's date>"}]}
        User: "What should I do next?" → {"reply": "Start with <task title>: <one short reason based on due date or priority>.", "operations": []}
        """

    // MARK: Parsing + validation

    static func parse(_ raw: String, request: String, index: TaskIndex, snapshot: Snapshot, now: Date,
                      providerName: String, isLocal: Bool) throws -> AIPlan {
        guard let json = extractJSON(raw) else {
            Log.write("AI unparseable: \(raw.prefix(300))")
            throw AIError.badResponse(raw)
        }
        var reply = (json["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var ops: [AIOperation] = []
        var rejected: [String] = []
        let requestDate = NaturalDate.find(in: request, now: now)
        // Small models like to invent priorities; only accept one when the user mentioned it.
        let mentionsPriority = request.range(of: #"\b(priority|urgent|important|asap|high|medium|low)\b"#,
                                             options: [.regularExpression, .caseInsensitive]) != nil
        let groups = Set(snapshot.tasks.compactMap(\.group))

        func ref(_ v: Any?) -> String? {
            let n: Int? = (v as? Int) ?? (v as? Double).map { Int($0) } ?? (v as? String).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) }
            return n.flatMap { index.id(for: $0) }
        }
        func day(_ v: Any?) -> String? {
            guard let s = v as? String, Dates.isValidDay(s) else { return nil }
            return s
        }
        func priority(_ v: Any?) -> Priority? {
            guard mentionsPriority else { return nil }
            return (v as? String).flatMap { Priority(rawValue: $0.lowercased()) }
        }
        func group(_ v: Any?) -> String? {
            guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
            return groups.first { $0.caseInsensitiveCompare(s) == .orderedSame } ?? s
        }
        func title(_ v: Any?) -> String? {
            guard var s = v as? String else { return nil }
            s = cleanTitle(s, requestDate: requestDate, original: request)
            return s.isEmpty ? nil : String(s.prefix(200))
        }

        let aliases = ["add_task": "create_task", "new_task": "create_task", "add_subtasks": "create_subtasks",
                       "break_down": "create_subtasks", "breakdown_task": "create_subtasks", "check_task": "complete_task",
                       "finish_task": "complete_task", "done": "complete_task", "mark_complete": "complete_task",
                       "uncheck_task": "reopen_task", "remove_task": "delete_task", "move_task": "update_task",
                       "reschedule_task": "update_task", "edit_task": "update_task", "set_due": "update_task",
                       "set_priority": "update_task", "rename_task": "update_task", "focus": "start_focus"]
        // Questions get answers, not edits ("What should I work on next?"). "Can you add…" is still a request.
        let lower = request.lowercased().trimmingCharacters(in: .whitespaces)
        let isQuestion = lower.hasSuffix("?") && ["what", "how", "which", "why", "when", "where", "who", "should", "is ", "am ", "do i", "did i"]
            .contains { lower.hasPrefix($0) }
        let byId = Dictionary(snapshot.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for case let item as [String: Any] in (isQuestion ? [] : (json["operations"] as? [Any] ?? [])) {
            let raw = (item["op"] as? String ?? "").lowercased()
            let op = aliases[raw] ?? raw
            switch op {
            case "create_task":
                guard let t = title(item["title"]) else { rejected.append("create_task without a title"); continue }
                // The deterministic parser beats a small model at weekday arithmetic.
                let due = requestDate?.day ?? day(item["due"])
                ops.append(.createTask(title: t, due: due, priority: priority(item["priority"]),
                                       group: group(item["group"]), parentId: ref(item["parent"])))
            case "create_subtasks":
                guard let p = ref(item["parent"]) else { rejected.append("create_subtasks with an unknown task"); continue }
                let titles = (item["titles"] as? [Any] ?? []).compactMap { title($0) }
                guard !titles.isEmpty else { rejected.append("create_subtasks without titles"); continue }
                ops.append(.createSubtasks(parentId: p, titles: Array(titles.prefix(12))))
            case "complete_task", "reopen_task", "delete_task", "start_focus":
                guard let id = ref(item["task"]) else { rejected.append("\(op) with an unknown task"); continue }
                switch op {
                case "complete_task":
                    guard byId[id]?.isDone == false else { rejected.append("already complete"); continue }
                    ops.append(.completeTask(id: id))
                case "reopen_task":
                    guard byId[id]?.isDone == true else { rejected.append("already open"); continue }
                    ops.append(.reopenTask(id: id))
                case "delete_task": ops.append(.deleteTask(id: id))
                default: ops.append(.startFocus(id: id, minutes: (item["minutes"] as? Int).map { max(5, min(120, $0)) }))
                }
            case "update_task":
                guard let id = ref(item["task"]) else { rejected.append("update_task with an unknown task"); continue }
                let newTitle = item["title"].flatMap { title($0) }
                var due: String?? = nil
                if item.keys.contains("due") { due = .some(requestDate?.day ?? day(item["due"])) }
                var pri: Priority?? = nil
                if item.keys.contains("priority"), mentionsPriority { pri = .some(priority(item["priority"])) }
                var grp: String?? = nil
                if let g = item["group"], !(g is NSNull) { grp = .some(group(g)) }
                if newTitle == nil && due == nil && pri == nil && grp == nil { rejected.append("update_task with no changes"); continue }
                ops.append(.updateTask(id: id, title: newTitle, due: due, priority: pri, group: grp))
            default:
                rejected.append("unknown operation \"\(op)\"")
            }
        }
        if reply.isEmpty && ops.isEmpty { throw AIError.badResponse(raw) }
        if reply.isEmpty { reply = "Here's what I'll do:" }
        return AIPlan(reply: reply, operations: ops, rejected: rejected, providerName: providerName, isLocal: isLocal)
    }

    static func extractJSON(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(raw[start...end])
        return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
    }

    static func cleanTitle(_ s: String, requestDate: NaturalDate.Match?, original: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["remind me to ", "remind me ", "i need to ", "i have to ", "todo: ", "task: "] {
            if t.lowercased().hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        }
        if let m = requestDate {
            let phrase = String(original[m.range])
            for p in [" before " + phrase, " by " + phrase, " on " + phrase, " " + phrase] {
                if let r = t.range(of: p, options: [.caseInsensitive]) { t.removeSubrange(r) }
            }
        }
        t = TaskLine.clean(t)
        if let first = t.first { t = first.uppercased() + t.dropFirst() }
        return t
    }

    /// Human-readable description of an operation for the confirmation list.
    public static func describe(_ op: AIOperation, snapshot: Snapshot) -> String {
        func name(_ id: String) -> String { "“\(snapshot.task(id)?.title ?? "task")”" }
        switch op {
        case .createTask(let title, let due, let priority, let group, let parent):
            var s = parent.map { "Add “\(title)” under \(name($0))" } ?? "Add “\(title)”"
            if let due { s += " · due \(Dates.dueLabel(due))" }
            if let priority { s += " · \(priority.rawValue)" }
            if let group, parent == nil { s += " · in \(group)" }
            return s
        case .createSubtasks(let parent, let titles):
            return "Break \(name(parent)) into \(titles.count) steps: " + titles.map { "“\($0)”" }.joined(separator: ", ")
        case .completeTask(let id): return "Complete \(name(id))"
        case .reopenTask(let id): return "Reopen \(name(id))"
        case .deleteTask(let id): return "Delete \(name(id))"
        case .startFocus(let id, let minutes): return "Start a \(minutes ?? snapshot.settings.defaultFocusMinutes)-minute focus on \(name(id))"
        case .updateTask(let id, let title, let due, let priority, let group):
            var parts: [String] = []
            if let title { parts.append("rename to “\(title)”") }
            if let due { parts.append(due.map { "due \(Dates.dueLabel($0))" } ?? "clear due date") }
            if let priority { parts.append(priority.map { "priority \($0.rawValue)" } ?? "clear priority") }
            if let group { parts.append(group.map { "move to \($0)" } ?? "move out of its group") }
            return "Update \(name(id)): " + parts.joined(separator: ", ")
        }
    }

    /// Applies validated operations through the normal service layer.
    public static func apply(_ ops: [AIOperation], service: TaskService, now: Date = Date()) throws {
        for op in ops {
            switch op {
            case .createTask(let title, let due, let priority, let group, let parent):
                try service.addTask(title: title, group: group, parentId: parent, due: due, priority: priority, now: now)
            case .createSubtasks(let parent, let titles):
                let pid = try service.ensurePersisted(parent)
                for t in titles { try service.addTask(title: t, parentId: pid, now: now) }
            case .completeTask(let id): try service.setDone(id, true, now: now)
            case .reopenTask(let id): try service.setDone(id, false, now: now)
            case .deleteTask(let id): try service.deleteTask(id)
            case .startFocus(let id, let minutes):
                if service.snapshot.active == nil {
                    try service.startFocus(taskId: id, minutes: minutes ?? service.snapshot.settings.defaultFocusMinutes, now: now)
                }
            case .updateTask(let id, let title, let due, let priority, let group):
                try service.updateTask(id, TaskPatch(title: title, priority: priority, due: due, group: group), now: now)
            }
        }
    }
}

/// Numbered view of the task list handed to the model. Numbers map back to real ids, so the model
/// can only reference tasks that exist.
struct TaskIndex {
    private(set) var entries: [(n: Int, task: TaskItem)] = []

    init(snapshot: Snapshot, now: Date) {
        // Open tasks first (they matter most), then today's completed ones; capped to fit small context windows.
        let visible = snapshot.visibleTasks(now: now)
        let ordered = visible.filter { !$0.isDone } + visible.filter(\.isDone)
        for (i, t) in ordered.prefix(80).enumerated() { entries.append((i + 1, t)) }
    }

    func id(for n: Int) -> String? { entries.first { $0.n == n }?.task.id }
    func number(for id: String?) -> Int? { entries.first { $0.task.id == id }?.n }

    func prompt(for request: String, snapshot: Snapshot, now: Date) -> String {
        let cal = Calendar.current
        let dayName = DateFormatter()
        dayName.dateFormat = "EEEE"
        var lines: [String] = []
        // Phrased as sentences: the on-device model's language check rejects prompts dominated by
        // bare dates and numbers.
        lines.append("The user says: \"\(request)\"")
        lines.append("")
        let week = (1...7).compactMap { cal.date(byAdding: .day, value: $0, to: now) }
            .map { "\(dayName.string(from: $0)) is \(Dates.dayKey($0))" }
        lines.append("Today is \(dayName.string(from: now)), \(Dates.dayKey(now)). In the coming week, " + week.joined(separator: ", ") + ".")
        let groups = Array(Set(snapshot.tasks.compactMap(\.group))).sorted()
        if !groups.isEmpty { lines.append("Their task groups are: " + groups.joined(separator: ", ") + ".") }
        lines.append("")
        lines.append(entries.isEmpty ? "They have no tasks yet." : "Their tasks, numbered:")
        let focus = snapshot.focusSeconds
        for (n, t) in entries {
            var attrs: [String] = [t.isDone ? "done" : "open"]
            if let p = number(for: t.parentId) { attrs.append("subtask of \(p)") }
            if let due = t.due { attrs.append("due \(due)") }
            if let pr = t.priority { attrs.append(pr.rawValue) }
            if let g = t.group { attrs.append("group \(g)") }
            if let f = focus[t.id], f > 0 { attrs.append("focused \(Dates.duration(f))") }
            lines.append("[\(n)] \(t.title) (\(attrs.joined(separator: ", ")))")
        }
        let startOfDay = cal.startOfDay(for: now)
        let today = snapshot.sessions.filter { $0.startedAt >= startOfDay }
        if !today.isEmpty {
            lines.append("")
            lines.append("Focus sessions today, \(Dates.duration(snapshot.focusTotal(since: startOfDay, now: now))) in total:")
            for s in today.reversed() {
                let secs = s.status.isActive ? s.elapsedSeconds(at: now) : s.actualSeconds
                lines.append("- \(Dates.duration(secs)) on \(s.taskTitle) (\(s.status.rawValue))")
            }
        }
        lines.append("")
        lines.append("Respond to the user's request with the JSON object.")
        return lines.joined(separator: "\n")
    }
}
