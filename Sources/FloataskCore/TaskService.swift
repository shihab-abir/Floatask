import Foundation

/// Everything the UI needs, rebuilt from the vault after every change.
public struct Snapshot {
    public var tasks: [TaskItem] = []          // file order, includes done tasks not yet archived
    public var sessions: [FocusSession] = []   // newest first
    public var settings = AppSettings()
    public var warnings: [String] = []

    public init() {}

    public var active: FocusSession? { sessions.first { $0.status.isActive } }

    public func task(_ id: String?) -> TaskItem? {
        guard let id else { return nil }
        return tasks.first { $0.id == id }
    }

    public func children(of id: String) -> [TaskItem] { tasks.filter { $0.parentId == id } }

    /// Tasks shown in the list: everything open, plus tasks completed today.
    /// A task completed on an earlier day is hidden once its whole subtree is done.
    public func visibleTasks(now: Date = Date(), calendar: Calendar = .current) -> [TaskItem] {
        let start = calendar.startOfDay(for: now)
        var hidden = Set<String>()
        var openChild = Set<String>()     // parents with at least one visible child
        for t in tasks.reversed() {
            let doneEarlier = t.isDone && (t.completedAt.map { $0 < start } ?? false)
            if doneEarlier && !openChild.contains(t.id) {
                hidden.insert(t.id)
            } else if let p = t.parentId {
                openChild.insert(p)
            }
        }
        return tasks.filter { !hidden.contains($0.id) }
    }

    public func progress(now: Date = Date()) -> (done: Int, total: Int) {
        let v = visibleTasks(now: now)
        return (v.filter(\.isDone).count, v.count)
    }

    /// The task to suggest next: the first open leaf task in list order.
    public func nextTask(now: Date = Date()) -> TaskItem? {
        let v = visibleTasks(now: now)
        let parents = Set(v.compactMap { $0.isDone ? nil : $0.parentId })
        return v.first { !$0.isDone && !parents.contains($0.id) }
    }

    /// Total recorded focus per task (finished sessions only; add the live session separately).
    public var focusSeconds: [String: Int] {
        var r: [String: Int] = [:]
        for s in sessions where !s.status.isActive { if let id = s.taskId { r[id, default: 0] += s.actualSeconds } }
        return r
    }

    public func focusTotal(since date: Date, now: Date = Date()) -> Int {
        sessions.reduce(0) { sum, s in
            guard s.startedAt >= date else { return sum }
            return sum + (s.status.isActive ? s.elapsedSeconds(at: now) : s.actualSeconds)
        }
    }
}

public enum FocusEvent {
    case completed(FocusSession)
}

/// The single application core. The GUI, the CLI and the AI layer all go through this.
public final class TaskService {
    public let layout: VaultLayout
    public private(set) var snapshot = Snapshot()
    private let lock = VaultLock()
    private var knownContent: [String: Int] = [:]    // path → hash of what we last read/wrote
    public var calendar = Calendar.current

    public init(layout: VaultLayout) throws {
        self.layout = layout
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: layout.vault.path, isDirectory: &isDir), isDir.boolValue else {
            throw FloataskError.vaultMissing(layout.vault.path)
        }
        try ensureFiles()
        try reload()
    }

    public static func fromLocalConfig() throws -> TaskService {
        guard let layout = LocalConfig.load().layout else { throw FloataskError.notConfigured }
        return try TaskService(layout: layout)
    }

    private func ensureFiles() throws {
        try lock.withLock {
            let fm = FileManager.default
            try fm.createDirectory(at: layout.folder, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: layout.tasks.path) {
                try SafeFile.write(TaskService.tasksTemplate, to: layout.tasks)
            }
            if !fm.fileExists(atPath: layout.sessions.path) {
                try SafeFile.write(SessionsDocument.serialize([]), to: layout.sessions)
            }
            if !fm.fileExists(atPath: layout.settings.path) {
                try SafeFile.write(SettingsDocument.serialize(AppSettings()), to: layout.settings)
            }
        }
    }

    static let tasksTemplate = """
        ---
        schema_version: 1
        type: task_manager_tasks
        ---

        # Tasks

        """

    // MARK: Loading

    @discardableResult
    public func reload() throws -> Snapshot {
        var s = Snapshot()
        let tasksText = try SafeFile.read(layout.tasks) ?? TaskService.tasksTemplate
        let sessionsText = try SafeFile.read(layout.sessions) ?? ""
        let settingsText = try SafeFile.read(layout.settings) ?? ""
        remember(layout.tasks, tasksText)
        remember(layout.sessions, sessionsText)
        remember(layout.settings, settingsText)
        s.tasks = TasksDocument.parse(tasksText).items()
        let parsed = SessionsDocument.parse(sessionsText)
        s.sessions = parsed.sessions.sorted { $0.startedAt > $1.startedAt }
        if parsed.skipped > 0 { s.warnings.append("\(parsed.skipped) focus session(s) in Sessions.md could not be read.") }
        s.settings = SettingsDocument.parse(settingsText)
        snapshot = s
        return s
    }

    /// True if any managed file differs from what the app last read or wrote.
    public func hasExternalChanges() -> Bool {
        for url in [layout.tasks, layout.sessions, layout.settings] {
            let text = (try? SafeFile.read(url)) ?? nil
            if knownContent[url.path] != (text ?? "").hashValue { return true }
        }
        return false
    }

    /// Tasks checked/unchecked in Obsidian need a completion timestamp; returns true if a write happened.
    @discardableResult
    public func stampExternalCompletions() throws -> Bool {
        let text = try SafeFile.read(layout.tasks) ?? ""
        guard TasksDocument.parse(text).needsDoneStamps else { return false }
        try mutateTasks { _ in }
        return true
    }

    private func remember(_ url: URL, _ text: String) { knownContent[url.path] = text.hashValue }

    // MARK: Write pipeline: read → parse → modify → validate → backup → atomic replace

    @discardableResult
    private func mutateTasks(now: Date = Date(), _ body: (inout TasksDocument) throws -> Void) throws -> [String: String] {
        let map: [String: String] = try lock.withLock {
            let original = try SafeFile.read(layout.tasks) ?? TaskService.tasksTemplate
            var doc = TasksDocument.parse(original)
            try body(&doc)
            var used = Set(doc.taskLines.map(\.id))
            let map = doc.normalize(now: now) { self.newTaskId(now: now, avoiding: &used) }
            let out = doc.serialize()
            try validate(out, expected: doc)
            if out != original {
                SafeFile.backup(layout.tasks, into: layout.backupDir)
                try SafeFile.write(out, to: layout.tasks)
            }
            remember(layout.tasks, out)
            return map
        }
        try reload()
        return map
    }

    private func validate(_ text: String, expected: TasksDocument) throws {
        let check = TasksDocument.parse(text)
        let a = check.taskLines, b = expected.taskLines
        guard a.count == b.count, zip(a, b).allSatisfy({ $0.id == $1.id && $0.isDone == $1.isDone && $0.title == $1.title }) else {
            Log.write("validation failed writing Tasks.md")
            throw FloataskError.validationFailed(layout.tasks.path)
        }
    }

    private func mutateSessions(_ body: (inout [FocusSession]) throws -> Void) throws {
        try lock.withLock {
            let original = try SafeFile.read(layout.sessions) ?? ""
            let parsed = SessionsDocument.parse(original)
            if parsed.skipped > 0 {
                // Unreadable items would be dropped by the rewrite — keep a copy first.
                SafeFile.backup(layout.sessions, into: layout.backupDir, minInterval: 0)
                Log.write("Sessions.md: \(parsed.skipped) unreadable item(s) backed up before rewrite")
            }
            var sessions = parsed.sessions
            try body(&sessions)
            let out = SessionsDocument.serialize(sessions)
            guard SessionsDocument.parse(out).sessions.count == sessions.count else {
                throw FloataskError.validationFailed(layout.sessions.path)
            }
            if out != original {
                SafeFile.backup(layout.sessions, into: layout.backupDir)
                try SafeFile.write(out, to: layout.sessions)
            }
            remember(layout.sessions, out)
        }
        try reload()
    }

    private func newTaskId(now: Date, avoiding used: inout Set<String>) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        while true {
            let id = "t_" + f.string(from: now) + "_" + String((0..<4).map { _ in alphabet.randomElement()! })
            if used.insert(id).inserted { return id }
        }
    }

    // MARK: Tasks

    @discardableResult
    public func addTask(title: String, group: String? = nil, parentId: String? = nil, due: String? = nil,
                        priority: Priority? = nil, tags: [String] = [], notes: String = "",
                        now: Date = Date()) throws -> String {
        let clean = TaskLine.clean(title)
        guard !clean.isEmpty else { throw FloataskError.invalid("A task needs a title.") }
        if let due, !Dates.isValidDay(due) { throw FloataskError.invalid("Due date must look like 2026-10-02.") }
        var parent = parentId
        if let p = parentId { parent = try ensurePersisted(p) }
        var newId = ""
        try mutateTasks(now: now) { doc in
            if let parent, doc.task(parent) == nil { throw FloataskError.taskNotFound(parent) }
            var used = Set(doc.taskLines.map(\.id))
            newId = newTaskId(now: now, avoiding: &used)
            var line = TaskLine(id: newId, title: clean, due: due, priority: priority)
            line.setTags(tags)
            line.setMeta("created", Dates.iso(now))
            if !notes.isEmpty { line.setNotes(notes) }
            let g = group.map(TaskLine.clean).flatMap { $0.isEmpty ? nil : $0 }
            doc.insert(line, group: g, parentId: parent)
        }
        return newId
    }

    /// Completes or reopens a task. Completing a parent completes its subtasks; completing the last
    /// open subtask completes the parent; reopening a subtask reopens its parents.
    public func setDone(_ id: String, _ done: Bool, now: Date = Date()) throws {
        var completed: [String] = []
        try mutateTasks(now: now) { doc in
            guard doc.task(id) != nil else { throw FloataskError.taskNotFound(id) }
            let items = doc.items()
            let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            var targets = [id]
            if done { targets += doc.descendantIds(of: id) }
            for t in targets where doc.task(t)?.isDone != done {
                _ = doc.modify(t) { $0.setDone(done, at: now) }
                if done { completed.append(t) }
            }
            // Walk up the ancestors.
            var cursor = byId[id]?.parentId
            while let p = cursor {
                let kids = doc.items().filter { $0.parentId == p }
                if done {
                    guard kids.allSatisfy(\.isDone), doc.task(p)?.isDone == false else { break }
                    _ = doc.modify(p) { $0.setDone(true, at: now) }
                    completed.append(p)
                } else if doc.task(p)?.isDone == true {
                    _ = doc.modify(p) { $0.setDone(false, at: now) }
                }
                cursor = byId[p]?.parentId
            }
        }
        if let active = snapshot.active, let tid = active.taskId, completed.contains(tid),
           snapshot.settings.completingTaskStopsFocus {
            try finishFocus(now: now)
        }
    }

    public func toggle(_ id: String, now: Date = Date()) throws {
        guard let t = snapshot.task(id) else { throw FloataskError.taskNotFound(id) }
        try setDone(id, !t.isDone, now: now)
    }

    public func updateTask(_ id: String, _ patch: TaskPatch, now: Date = Date()) throws {
        if let title = patch.title, TaskLine.clean(title).isEmpty { throw FloataskError.invalid("A task needs a title.") }
        if let due = patch.due, let d = due, !Dates.isValidDay(d) { throw FloataskError.invalid("Due date must look like 2026-10-02.") }
        try mutateTasks(now: now) { doc in
            guard doc.task(id) != nil else { throw FloataskError.taskNotFound(id) }
            _ = doc.modify(id) { t in
                if let v = patch.title { t.setTitle(v) }
                if let v = patch.notes { t.setNotes(v) }
                if let v = patch.priority { t.setPriority(v) }
                if let v = patch.due { t.setDue(v) }
                if let v = patch.tags { t.setTags(v) }
            }
            if let g = patch.group {
                let target = g.map(TaskLine.clean).flatMap { $0.isEmpty ? nil : $0 }
                let current = doc.items().first { $0.id == id }
                if current?.group != target || current?.depth != 0 {
                    let lines = doc.removeSubtree(id)
                    doc.insertSubtree(lines, group: target)
                }
            }
        }
    }

    public func deleteTask(_ id: String) throws {
        try mutateTasks { doc in
            guard doc.task(id) != nil else { throw FloataskError.taskNotFound(id) }
            doc.removeSubtree(id)
        }
    }

    @discardableResult
    public func duplicateTask(_ id: String, now: Date = Date()) throws -> String {
        guard let t = snapshot.task(id) else { throw FloataskError.taskNotFound(id) }
        return try addTask(title: t.title, group: t.group, parentId: t.parentId, due: t.due,
                           priority: t.priority, tags: t.tags, notes: t.notes, now: now)
    }

    /// Tasks typed in Obsidian have no id until the app first writes the file; this assigns one.
    public func ensurePersisted(_ id: String) throws -> String {
        guard id.hasPrefix("tmp_") else { return id }
        let map = try mutateTasks { _ in }
        guard let real = map[id] else { throw FloataskError.taskNotFound(id) }
        return real
    }

    // MARK: Daily rollover → Archive/YYYY-MM.md

    /// Moves fully-completed task trees that were finished before today into the monthly archive.
    @discardableResult
    public func rollover(now: Date = Date()) throws -> Int {
        let start = calendar.startOfDay(for: now)
        var moved = 0
        try lock.withLock {
            let original = try SafeFile.read(layout.tasks) ?? TaskService.tasksTemplate
            var doc = TasksDocument.parse(original)
            let items = doc.items()
            let roots = items.filter { root in
                guard root.depth == 0, root.hasPersistedId, root.isDone else { return false }
                let subtree = [root] + items.filter { isDescendant($0, of: root.id, in: items) }
                return subtree.allSatisfy { $0.isDone && ($0.completedAt.map { $0 < start } ?? false) }
            }
            guard !roots.isEmpty else { return }

            // Group by archive month; write archives first so a crash can only duplicate, never lose.
            var byMonth: [String: [(TaskItem, [TaskLine])]] = [:]
            var working = doc
            for root in roots {
                let lines = working.removeSubtree(root.id)
                byMonth[Dates.monthKey(root.completedAt!, calendar: calendar), default: []].append((root, lines))
            }
            for (month, entries) in byMonth {
                let url = layout.archive(month: month)
                var archive = try SafeFile.read(url).map(TasksDocument.parse)
                    ?? TasksDocument.empty(type: "task_manager_archive", title: "Archive \(month)")
                for (root, var lines) in entries where archive.task(root.id) == nil {
                    if let g = root.group { lines[0].setMeta("group", g) }
                    archive.insertSubtree(lines, group: Dates.dayKey(root.completedAt!, calendar: calendar))
                }
                try SafeFile.write(archive.serialize(), to: url)
            }
            doc = working
            let out = doc.serialize()
            try validate(out, expected: doc)
            SafeFile.backup(layout.tasks, into: layout.backupDir)
            try SafeFile.write(out, to: layout.tasks)
            remember(layout.tasks, out)
            moved = roots.count
        }
        if moved > 0 { try reload() }
        return moved
    }

    private func isDescendant(_ t: TaskItem, of id: String, in items: [TaskItem]) -> Bool {
        var p = t.parentId
        while let cur = p {
            if cur == id { return true }
            p = items.first { $0.id == cur }?.parentId
        }
        return false
    }

    /// Completed tasks for History: today's (still in Tasks.md) plus the archive for recent months.
    public func completedTasks(monthsBack: Int = 3, now: Date = Date()) -> [TaskItem] {
        var result = snapshot.tasks.filter(\.isDone)
        for back in 0...monthsBack {
            guard let d = calendar.date(byAdding: .month, value: -back, to: now),
                  let text = try? SafeFile.read(layout.archive(month: Dates.monthKey(d, calendar: calendar))) else { continue }
            result += TasksDocument.parse(text).items().filter(\.isDone)
        }
        return result.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    // MARK: Focus sessions

    public func startFocus(taskId: String?, minutes: Int, now: Date = Date()) throws {
        guard snapshot.active == nil else { throw FloataskError.invalid("A focus session is already running.") }
        let s = snapshot.settings
        let planned = min(s.maxFocusMinutes, max(s.minFocusMinutes, minutes))
        var tid = taskId
        if let t = taskId { tid = try ensurePersisted(t) }
        let title = snapshot.task(tid)?.title ?? "Unassigned"
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        var id = "fs_" + f.string(from: now)
        if snapshot.sessions.contains(where: { $0.id == id }) { id += "_\(Int.random(in: 10...99))" }
        let session = FocusSession(id: id, taskId: tid, taskTitle: title, startedAt: now,
                                   plannedMinutes: planned, status: .running)
        try mutateSessions { $0.append(session) }
    }

    private func mutateActive(_ body: (inout FocusSession) throws -> Void) throws {
        guard let activeId = snapshot.active?.id else { throw FloataskError.noActiveSession }
        try mutateSessions { sessions in
            guard let i = sessions.firstIndex(where: { $0.id == activeId && $0.status.isActive }) else {
                throw FloataskError.noActiveSession
            }
            try body(&sessions[i])
        }
    }

    public func pauseFocus(now: Date = Date()) throws {
        try mutateActive { s in
            guard s.status == .running else { return }
            s.status = .paused
            s.pausedAt = now
        }
    }

    public func resumeFocus(now: Date = Date()) throws {
        try mutateActive { s in
            guard s.status == .paused, let p = s.pausedAt else { return }
            s.pausedSeconds += max(0, Int(now.timeIntervalSince(p)))
            s.pausedAt = nil
            s.status = .running
        }
    }

    /// Changes the planned length of the running session (never below what has already elapsed + 1 min).
    public func adjustFocus(byMinutes delta: Int, now: Date = Date()) throws {
        let st = snapshot.settings
        try mutateActive { s in
            let floor = max(st.minFocusMinutes, s.elapsedSeconds(at: now) / 60 + 1)
            s.plannedMinutes = min(st.maxFocusMinutes, max(floor, s.plannedMinutes + delta))
        }
    }

    /// Ends the session now. Sessions shorter than a minute are discarded.
    public func finishFocus(now: Date = Date()) throws {
        try endActive(status: .endedEarly, now: now)
    }

    public func resetFocus(now: Date = Date()) throws {
        try endActive(status: .interrupted, now: now)
    }

    private func endActive(status: SessionStatus, now: Date) throws {
        guard let activeId = snapshot.active?.id else { throw FloataskError.noActiveSession }
        try mutateSessions { sessions in
            guard let i = sessions.firstIndex(where: { $0.id == activeId }) else { return }
            var s = sessions[i]
            let elapsed = s.elapsedSeconds(at: now)
            if elapsed < 60 { sessions.remove(at: i); return }
            if s.status == .paused, let p = s.pausedAt { s.pausedSeconds += max(0, Int(now.timeIntervalSince(p))) }
            s.actualSeconds = min(elapsed, s.plannedSeconds)
            s.endedAt = now
            s.pausedAt = nil
            s.status = elapsed >= s.plannedSeconds ? .completed : status
            sessions[i] = s
        }
    }

    /// Brings session state in line with the clock: completes timers that ran out (even while the
    /// app was closed), closes stale duplicates. Returns the session that just completed, if any.
    @discardableResult
    public func reconcileFocus(now: Date = Date()) throws -> FocusEvent? {
        let actives = snapshot.sessions.filter { $0.status.isActive }
        guard !actives.isEmpty else { return nil }
        let needsWork = actives.count > 1 || actives.contains { s in
            (s.status == .running && s.remainingSeconds(at: now) == 0)
                || (s.status == .paused && now.timeIntervalSince(s.pausedAt ?? now) > 8 * 3600)
        }
        guard needsWork else { return nil }
        var event: FocusEvent?
        var touched = Set<String>()
        try mutateSessions { sessions in
            let newestActive = sessions.filter { $0.status.isActive }.max { $0.startedAt < $1.startedAt }?.id
            for i in sessions.indices where sessions[i].status.isActive {
                var s = sessions[i]
                if s.id != newestActive {
                    s.actualSeconds = min(s.plannedSeconds, s.elapsedSeconds(at: s.pausedAt ?? now))
                    s.endedAt = s.pausedAt ?? now
                    s.status = .interrupted
                } else if s.status == .running && s.remainingSeconds(at: now) == 0 {
                    s.actualSeconds = s.plannedSeconds
                    s.endedAt = s.expectedEnd
                    s.status = .completed
                    event = .completed(s)
                } else if s.status == .paused, let p = s.pausedAt, now.timeIntervalSince(p) > 8 * 3600 {
                    s.actualSeconds = s.elapsedSeconds(at: p)
                    s.pausedSeconds += Int(now.timeIntervalSince(p))
                    s.endedAt = p
                    s.pausedAt = nil
                    s.status = .interrupted
                } else {
                    continue
                }
                s.pausedAt = nil
                sessions[i] = s
                touched.insert(s.id)
            }
            sessions.removeAll { touched.contains($0.id) && $0.actualSeconds < 60 }
        }
        return event
    }

    // MARK: Settings

    public func updateSettings(_ settings: AppSettings) throws {
        try lock.withLock {
            let fresh = TasksDocument.parse(SettingsDocument.serialize(settings))
            var doc = try SafeFile.read(layout.settings).map(TasksDocument.parse) ?? fresh
            doc.frontmatter = fresh.frontmatter
            if doc.blocks.isEmpty { doc.blocks = fresh.blocks }
            let out = doc.serialize()
            try SafeFile.write(out, to: layout.settings)
            remember(layout.settings, out)
        }
        try reload()
    }
}
