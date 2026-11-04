import AppKit
import Foundation

// floatask — terminal front-end. Uses the same TaskService as the app, so data can't drift.

let bundleId = AppIdentity.bundleId
let commandNotification = AppIdentity.commandNotification
let tty = isatty(STDOUT_FILENO) != 0

func style(_ s: String, _ code: String) -> String { tty ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
func dim(_ s: String) -> String { style(s, "2") }
func bold(_ s: String) -> String { style(s, "1") }
func green(_ s: String) -> String { style(s, "32") }
func amber(_ s: String) -> String { style(s, "33") }

func percent(_ p: (done: Int, total: Int)) -> Int {
    p.total == 0 ? 0 : Int((Double(p.done) / Double(p.total) * 100).rounded())
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("floatask: \(message)\n".utf8))
    exit(code)
}

func service() -> TaskService {
    do {
        let s = try TaskService.fromLocalConfig()
        try s.reconcileFocus()
        try s.rollover()
        return s
    } catch FloataskError.notConfigured {
        fail("no vault configured yet. Run: floatask config \"/path/to/your/vault\"")
    } catch FloataskError.vaultMissing(let path) {
        fail("your Obsidian vault could not be found at \(path). Run: floatask config \"/path/to/vault\"")
    } catch {
        fail(error.localizedDescription)
    }
}

func run(_ body: () throws -> Void) {
    do { try body() } catch { fail(error.localizedDescription) }
}

// MARK: App control

var appIsRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty }

func send(_ command: String) {
    DistributedNotificationCenter.default().postNotificationName(
        commandNotification, object: command, userInfo: nil, deliverImmediately: true)
}

func openApp() {
    if appIsRunning { send("show"); return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-b", bundleId]
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        fail("couldn't find Floatask.app. Reinstall it: https://github.com/shihab-abir/Floatask#install")
    }
}

// MARK: Resolving "3" or "t_20260930_ab12" to a task

/// The list arrangement chosen in the app (Up next / Groups / Priority); the CLI numbers tasks the same way.
var listView: ListView { LocalConfig.load().listView.flatMap(ListView.init(rawValue:)) ?? .groups }

func visibleNumbered(_ s: TaskService) -> [TaskItem] {
    let visible = s.snapshot.visibleTasks()
    switch listView {
    case .groups: return visible
    case .upNext: return Snapshot.upNext(visible)
    case .priority:
        let ordered = Snapshot.upNext(visible)
        let rootPriority = priorityOfRoot(ordered)
        return [Priority.high, .medium, .low, nil].flatMap { p in ordered.filter { rootPriority[$0.id]! == p } }
    }
}

/// Each task's top-level task priority (subtasks are listed with their parent).
func priorityOfRoot(_ ordered: [TaskItem]) -> [String: Priority?] {
    var map: [String: Priority?] = [:]
    var current: Priority?
    for t in ordered {
        if t.depth == 0 { current = t.priority }
        map[t.id] = .some(current)
    }
    return map
}

func resolve(_ ref: String, in s: TaskService) -> TaskItem {
    let list = visibleNumbered(s)
    if let n = Int(ref), n >= 1, n <= list.count { return list[n - 1] }
    if let t = s.snapshot.task(ref) { return t }
    let matches = list.filter { $0.title.localizedCaseInsensitiveContains(ref) }
    if matches.count == 1 { return matches[0] }
    if matches.count > 1 { fail("\"\(ref)\" matches \(matches.count) tasks — use the number from `floatask list`.") }
    fail("no task \"\(ref)\". Use the number shown by `floatask list`.")
}

// MARK: Printing

func printList(_ s: TaskService) {
    let list = visibleNumbered(s)
    let p = s.snapshot.progress()
    if list.isEmpty {
        print("No tasks yet.  Add one: floatask add \"Write project documentation\"")
        return
    }
    let pct = percent(p)
    let barWidth = 24
    let filled = p.total == 0 ? 0 : Int((Double(p.done) / Double(p.total) * Double(barWidth)).rounded())
    print(bold("OPEN TASKS") + "  " + green(String(repeating: "━", count: filled)) + dim(String(repeating: "─", count: barWidth - filled)) + "  \(pct)%  " + dim("\(p.done)/\(p.total)"))
    print("")
    let focus = s.snapshot.focusSeconds
    let width = String(list.count).count
    let view = listView
    let rootPriority = priorityOfRoot(list)
    var lastHeader: String?? = .none
    for (i, t) in list.enumerated() {
        if t.depth == 0 {
            let header: String? = switch view {
            case .groups: t.group
            case .priority: rootPriority[t.id]!.map { $0.rawValue.capitalized } ?? "No priority"
            case .upNext: nil
            }
            if lastHeader != .some(header) {
                if let header { print(""); print(dim(header.uppercased())) }
                lastHeader = .some(header)
            }
        }
        let num = String(repeating: " ", count: width - String(i + 1).count) + "\(i + 1)"
        let box = t.isDone ? green("☑") : "☐"
        let indent = String(repeating: "   ", count: t.depth)
        var line = "\(dim(num))  \(indent)\(box) " + (t.isDone ? dim(t.title) : t.title)
        var meta: [String] = []
        if let due = t.due { meta.append(Dates.dueLabel(due)) }
        if let pr = t.priority, pr == .high { meta.append("high") }
        if let f = focus[t.id], f > 0 { meta.append(Dates.duration(f)) }
        if !meta.isEmpty { line += "  " + dim(meta.joined(separator: " · ")) }
        print(line)
    }
}

func printStatus(_ s: TaskService) {
    let p = s.snapshot.progress()
    let start = Calendar.current.startOfDay(for: Date())
    print("\(bold("Tasks"))   \(p.done)/\(p.total) done" + (p.total > 0 ? " (\(percent(p))%)" : ""))
    if let a = s.snapshot.active {
        let state = a.status == .paused ? "paused" : "running"
        print("\(bold("Focus"))   \(amber(Dates.clock(a.remainingSeconds(at: Date())))) left · \(state) · \(a.taskTitle)")
    } else {
        print("\(bold("Focus"))   idle")
    }
    print("\(bold("Today"))   \(Dates.duration(s.snapshot.focusTotal(since: start))) focused")
    if let n = s.snapshot.nextTask() { print("\(bold("Next"))    \(n.title)") }
    print(dim("App: \(appIsRunning ? "running" : "not running") · Vault: \(s.layout.vault.path)"))
}

func printHistory(_ s: TaskService) {
    let cal = Calendar.current
    let now = Date()
    let startOfWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
    print("\(bold("Today"))      \(Dates.duration(s.snapshot.focusTotal(since: cal.startOfDay(for: now))))")
    print("\(bold("This week"))  \(Dates.duration(s.snapshot.focusTotal(since: startOfWeek)))")
    let byDay = Dictionary(grouping: s.snapshot.sessions.prefix(60)) { Dates.dayKey($0.startedAt) }
    for day in byDay.keys.sorted(by: >).prefix(7) {
        print("")
        print(dim(day == Dates.dayKey(now) ? "TODAY" : day))
        for session in byDay[day]!.sorted(by: { $0.startedAt > $1.startedAt }) {
            let secs = session.status.isActive ? session.elapsedSeconds(at: now) : session.actualSeconds
            let mark = session.status == .completed ? "" : dim(" (\(session.status.rawValue.replacingOccurrences(of: "_", with: " ")))")
            print("  \(Dates.duration(secs).padding(toLength: 7, withPad: " ", startingAt: 0)) \(session.taskTitle)\(mark)")
        }
    }
    if s.snapshot.sessions.isEmpty { print("\nNo focus sessions yet. Start one with: floatask focus 1") }
}

func usage() {
    print("""
    \(bold("floatask")) — floating task manager backed by your Obsidian vault

    \(bold("App"))
      floatask                 open the floating panel (same as `floatask open`)
      floatask hide            collapse the panel to the small floating button
      floatask quit            close the app (a running timer keeps its state)

    \(bold("Tasks"))
      floatask list            show open tasks with numbers   (alias: today, ls)
      floatask add "Title" [--due tomorrow|2026-10-02] [--group Name] [--priority high|medium|low] [--under N]
      floatask done N          complete task number N          (undo N reopens it)
      floatask rm N            delete task N (asks first)
      floatask move N top|up|down|bottom|POS   change where task N sits in "Up next"

    \(bold("Focus"))
      floatask focus N [MIN]   start a focus session on task N (default length from settings)
      floatask pause | resume | stop
      floatask status          compact summary
      floatask history         recent focus sessions and totals

    \(bold("Assistant"))
      floatask ask "Break the website launch into steps"

    \(bold("Setup"))
      floatask config          show configuration
      floatask config PATH     use the Obsidian vault at PATH
      floatask version
    """)
}

func flag(_ name: String, in args: inout [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

func confirm(_ question: String) -> Bool {
    print(question + " [y/N] ", terminator: "")
    return (readLine() ?? "").lowercased().hasPrefix("y")
}

// MARK: Dispatch

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "open" : args.removeFirst()

switch command {
case "open", "show":
    if LocalConfig.load().layout == nil && !appIsRunning {
        print("Tip: set your vault first with  floatask config \"/path/to/vault\"  (or choose it in the app).")
    }
    openApp()

case "hide", "minimize":
    guard appIsRunning else { fail("Floatask isn't running. Open it with: floatask") }
    send("hide")

case "quit", "close":
    guard appIsRunning else { print("Floatask isn't running."); exit(0) }
    send("quit")
    print("Closing Floatask.")

case "config":
    var config = LocalConfig.load()
    if let path = args.first {
        let expanded = (path as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            fail("no folder at \(url.path)")
        }
        // Obsidian vaults contain a .obsidian folder; accept a parent that holds exactly one vault.
        if !FileManager.default.fileExists(atPath: url.appendingPathComponent(".obsidian").path) {
            let inner = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(".obsidian").path) }
            if inner.count == 1 {
                print("Using the vault inside that folder: \(inner[0].lastPathComponent)")
                url = inner[0]
            } else {
                print(amber("Note: this folder has no .obsidian directory, so it may not be an Obsidian vault."))
            }
        }
        config.vaultPath = url.path
        if let folder = flag("--folder", in: &args) { config.folderName = folder }
        run { try config.save() }
        run { _ = try TaskService(layout: config.layout!) }
        print("Vault set to \(url.path)")
        print("Floatask files live in \(config.layout!.folder.path)")
        if appIsRunning { send("reload") }
    } else {
        print("Vault:    \(config.vaultPath ?? "(not set)")")
        print("Folder:   \(config.folderName)")
        print("Config:   \(LocalConfig.fileURL.path)")
        print("Settings: \(config.layout.map { $0.settings.path } ?? "-")  (timer, AI and appearance options)")
    }

case "list", "ls", "today":
    printList(service())

case "status":
    printStatus(service())

case "history":
    printHistory(service())

case "add":
    let s = service()
    let due = flag("--due", in: &args)
    let group = flag("--group", in: &args)
    let priority = flag("--priority", in: &args)
    let under = flag("--under", in: &args)
    let title = args.joined(separator: " ")
    guard !title.isEmpty else { fail("usage: floatask add \"Task title\"") }
    var dueDay: String?
    if let due {
        dueDay = Dates.isValidDay(due) ? due : NaturalDate.find(in: due)?.day
        if dueDay == nil { fail("couldn't understand the due date \"\(due)\"") }
    }
    var pr: Priority?
    if let priority {
        guard let p = Priority(rawValue: priority.lowercased()) else { fail("priority must be high, medium or low") }
        pr = p
    }
    let parent = under.map { resolve($0, in: s).id }
    run {
        try s.addTask(title: title, group: group, parentId: parent, due: dueDay, priority: pr)
        print(green("✓") + " Added “\(TaskLine.clean(title))”" + (dueDay.map { dim(" · due \(Dates.dueLabel($0))") } ?? ""))
    }

case "done", "check", "undo", "uncheck":
    guard let ref = args.first else { fail("usage: floatask \(command) N") }
    let s = service()
    let t = resolve(ref, in: s)
    let done = command == "done" || command == "check"
    run {
        try s.setDone(t.id, done)
        print(green("✓") + (done ? " Completed" : " Reopened") + " “\(t.title)”")
        let p = s.snapshot.progress()
        if p.total > 0 { print(dim("\(p.done)/\(p.total) done · \(percent(p))%")) }
    }

case "move", "mv":
    guard args.count >= 2 else { fail("usage: floatask move N top|up|down|bottom|POSITION") }
    let s = service()
    let t = resolve(args[0], in: s)
    guard t.depth == 0 else { fail("subtasks move with their parent task.") }
    let roots = Snapshot.upNext(s.snapshot.visibleTasks()).filter { $0.depth == 0 }.map(\.id)
    let current = roots.firstIndex(of: t.id) ?? 0
    let target: Int
    switch args[1].lowercased() {
    case "top", "first": target = 0
    case "bottom", "last": target = roots.count - 1
    case "up": target = max(0, current - 1)
    case "down": target = min(roots.count - 1, current + 1)
    default:
        guard let n = Int(args[1]), n >= 1 else { fail("position must be top, up, down, bottom or a number") }
        target = min(n, roots.count) - 1
    }
    run {
        try s.move(t.id, to: target)
        print(green("✓") + " “\(t.title)” is now #\(target + 1) of \(roots.count) in Up next")
    }

case "rm", "delete":
    guard let ref = args.first else { fail("usage: floatask rm N") }
    let s = service()
    let t = resolve(ref, in: s)
    let kids = s.snapshot.tasks.filter { $0.parentId == t.id }.count
    guard confirm("Delete “\(t.title)”\(kids > 0 ? " and its \(kids) subtask(s)" : "")?") else { print("Kept."); exit(0) }
    run { try s.deleteTask(t.id); print("Deleted.") }

case "focus", "start":
    let s = service()
    if let a = s.snapshot.active {
        print("Already focusing on “\(a.taskTitle)” — \(Dates.clock(a.remainingSeconds(at: Date()))) left.")
        exit(0)
    }
    guard let ref = args.first else {
        openApp()
        print("Pick a task in the panel, or run: floatask focus N")
        exit(0)
    }
    let t = resolve(ref, in: s)
    let minutes = args.dropFirst().first.flatMap(Int.init) ?? s.snapshot.settings.defaultFocusMinutes
    run {
        try s.startFocus(taskId: t.id, minutes: minutes)
        print(amber("◉") + " Focusing on “\(t.title)” for \(s.snapshot.active?.plannedMinutes ?? minutes) min")
    }
    if appIsRunning { send("reload") } else { openApp() }

case "pause":
    let s = service(); run { try s.pauseFocus(); print("Paused.") }
case "resume":
    let s = service(); run { try s.resumeFocus(); print("Resumed.") }
case "stop", "finish":
    let s = service()
    guard let a = s.snapshot.active else { print("No focus session running."); exit(0) }
    run { try s.finishFocus(); print("Stopped. Logged \(Dates.duration(a.elapsedSeconds(at: Date()))) on “\(a.taskTitle)”.") }

case "ask", "ai":
    let s = service()
    let request = args.joined(separator: " ")
    guard !request.isEmpty else { fail("usage: floatask ask \"what should I work on next?\"") }
    let settings = s.snapshot.settings
    guard settings.aiEnabled else { fail("the assistant is turned off in Settings.md (ai_enabled: false)") }
    let provider: AIProvider = settings.aiProvider == "anthropic"
        ? AnthropicProvider(model: settings.aiModel) : AppleIntelligenceProvider()
    if case .unavailable(let why) = provider.availability() { fail(why) }
    print(dim(provider.isLocal ? "Thinking on this Mac…" : "Sending to \(provider.displayName)…"))
    let sem = DispatchSemaphore(value: 0)
    var outcome: Result<AIPlan, Error>!
    let snapshot = s.snapshot
    Task {
        do { outcome = .success(try await AIPlanner(provider: provider).plan(request, snapshot: snapshot)) }
        catch { outcome = .failure(error) }
        sem.signal()
    }
    sem.wait()
    switch outcome! {
    case .failure(let e): fail(e.localizedDescription)
    case .success(let plan):
        print(plan.reply)
        guard !plan.operations.isEmpty else { exit(0) }
        print("")
        for op in plan.operations {
            print((op.isDestructive ? amber("  ! ") : "  • ") + AIPlanner.describe(op, snapshot: s.snapshot))
        }
        guard confirm("\nApply?") else { print("Nothing changed."); exit(0) }
        run { try AIPlanner.apply(plan.operations, service: s); print(green("✓") + " Done.") }
    }

case "version", "--version", "-v":
    print("floatask \(AppIdentity.version) (\(AppIdentity.commit))")

case "help", "-h", "--help":
    usage()

default:
    print("Unknown command “\(command)”.\n")
    usage()
    exit(1)
}
