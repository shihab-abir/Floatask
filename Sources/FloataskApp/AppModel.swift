import AppKit
import SwiftUI
import UserNotifications

enum Route: Equatable {
    case tasks
    case history
    case assistant
    case settings
    case edit(String)
    case picker
}

struct Banner: Equatable {
    var message: String
    var detail: String?
    var retry: Bool = false
}

/// UI state + actions. All persistence goes through TaskService; this class never writes files.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published var now = Date()
    @Published var route: Route = .tasks
    @Published var focusTaskId: String?
    @Published var highlightedId: String?
    @Published var pendingMinutes = 25
    @Published var banner: Banner?
    @Published var pendingSwitch: String?            // task id awaiting "switch task?" confirmation
    @Published var pendingDelete: String?
    @Published var needsVault = false
    @Published var collapsedGroups: Set<String> = []
    @Published var addingUnder: String?              // parent id while adding a subtask inline
    @Published var addingGroup: String?              // group name while adding into a group
    @Published var justCompleted: FocusSession?      // shown briefly after a timer finishes
    @Published var focusAddField = 0                 // bump to focus the add-task field
    @Published var focusAssistantField = 0

    private(set) var service: TaskService?
    private(set) var config = LocalConfig.load()
    private var ticker: Timer?
    private var watcher: FileWatcher?
    private var lastDay = Dates.dayKey(Date())
    private var stampWork: DispatchWorkItem?

    var onAppearanceChange: (() -> Void)?

    init() {
        focusTaskId = config.selectedTaskId
        collapsedGroups = Set(config.collapsedGroups)
        connect()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker!, forMode: .common)
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayChanged() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadFromDisk() }
        }
    }

    // MARK: Vault connection

    func connect() {
        config = LocalConfig.load()
        guard let layout = config.layout else { needsVault = true; return }
        do {
            let s = try TaskService(layout: layout)
            service = s
            needsVault = false
            try s.reconcileFocus()
            try s.rollover()
            try s.stampExternalCompletions()
            refresh()
            pendingMinutes = config.pendingMinutes ?? snapshot.settings.defaultFocusMinutes
            if let id = focusTaskId, snapshot.task(id) == nil || snapshot.task(id)?.isDone == true { focusTaskId = nil }
            if let active = snapshot.active { focusTaskId = active.taskId ?? focusTaskId }
            watcher = FileWatcher(url: layout.folder) { [weak self] in
                MainActor.assumeIsolated { self?.externalChange() }
            }
            Notifier.requestAuthorization()
            rescheduleNotification()
        } catch FloataskError.vaultMissing {
            needsVault = true
            show(Banner(message: "Your Obsidian vault could not be found.", detail: layout.vault.path))
        } catch {
            needsVault = service == nil
            show(error)
        }
    }

    func chooseVault(_ url: URL) {
        var c = LocalConfig.load()
        c.vaultPath = url.path
        do { try c.save() } catch { show(error); return }
        banner = nil
        connect()
    }

    private func refresh() {
        guard let service else { return }
        let oldTheme = snapshot.settings.theme, oldOpacity = snapshot.settings.opacity
        snapshot = service.snapshot
        if let w = snapshot.warnings.first { show(Banner(message: "Some task data could not be read.", detail: w)) }
        if oldTheme != snapshot.settings.theme || oldOpacity != snapshot.settings.opacity { onAppearanceChange?() }
    }

    func reloadFromDisk() {
        guard let service else { connect(); return }
        run { try service.reload(); try service.reconcileFocus() }
    }

    private func externalChange() {
        guard let service, service.hasExternalChanges() else { return }
        run { try service.reload() }
        // Stamp completion times for boxes ticked in Obsidian — debounced so we don't write mid-edit.
        stampWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let service = self.service else { return }
                self.run { try service.stampExternalCompletions() }
            }
        }
        stampWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        rescheduleNotification()
    }

    // MARK: Clock

    private func tick() {
        now = Date()
        if Dates.dayKey(now) != lastDay { dayChanged() }
        if let a = snapshot.active, a.status == .running, a.remainingSeconds(at: now) == 0 {
            completeIfDue()
        }
        if let j = justCompleted, now.timeIntervalSince(j.endedAt ?? now) > 12 { justCompleted = nil }
    }

    private func dayChanged() {
        lastDay = Dates.dayKey(Date())
        guard let service else { return }
        run { try service.rollover() }
    }

    private func completeIfDue() {
        guard let service else { return }
        do {
            if case .completed(let s)? = try service.reconcileFocus(now: Date()) {
                justCompleted = s
                if snapshot.settings.sound { NSSound(named: "Glass")?.play() }
            }
            refresh()
        } catch { show(error) }
    }

    // MARK: Derived

    var visibleTasks: [TaskItem] { snapshot.visibleTasks(now: now) }
    var progress: (done: Int, total: Int) { snapshot.progress(now: now) }
    var active: FocusSession? { snapshot.active }
    var focusTask: TaskItem? { snapshot.task(active?.taskId ?? focusTaskId) }
    var groups: [String] {
        var seen: [String] = []
        for t in snapshot.tasks { if let g = t.group, !seen.contains(g) { seen.append(g) } }
        return seen
    }

    func focusSeconds(for id: String) -> Int {
        var s = snapshot.focusSeconds[id] ?? 0
        if let a = active, a.taskId == id { s += a.elapsedSeconds(at: now) }
        return s
    }

    var timerSeconds: Int {
        if let a = active { return a.remainingSeconds(at: now) }
        return pendingMinutes * 60
    }

    // MARK: Task actions

    func addTask(_ title: String, parentId: String? = nil, group: String? = nil) {
        guard let service, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        run { try service.addTask(title: title, group: group, parentId: parentId) }
    }

    func toggle(_ id: String) {
        guard let service else { return }
        run { try service.toggle(id) }
        if let f = focusTaskId, snapshot.task(f)?.isDone == true, active == nil { focusTaskId = nil; persistSelection() }
        rescheduleNotification()
    }

    func update(_ id: String, _ patch: TaskPatch) {
        guard let service else { return }
        run { try service.updateTask(id, patch) }
    }

    func delete(_ id: String) {
        guard let service else { return }
        run { try service.deleteTask(id) }
        if focusTaskId == id { focusTaskId = nil; persistSelection() }
        pendingDelete = nil
        if case .edit(id) = route { route = .tasks }
    }

    func duplicate(_ id: String) {
        guard let service else { return }
        run { try service.duplicateTask(id) }
    }

    func toggleGroup(_ g: String) {
        if collapsedGroups.contains(g) { collapsedGroups.remove(g) } else { collapsedGroups.insert(g) }
        config.collapsedGroups = Array(collapsedGroups)
        try? config.save()
    }

    // MARK: Focus actions

    /// Makes a task the focus target. While a session runs, switching needs confirmation.
    func selectFocusTask(_ id: String?) {
        if let a = active, a.taskId != id {
            pendingSwitch = id ?? ""
            return
        }
        focusTaskId = id
        persistSelection()
        if route == .picker { route = .tasks }
    }

    /// Confirmed switch: ends the current session (logging its time) and starts one on the new task.
    func confirmSwitch() {
        guard let service, let target = pendingSwitch else { return }
        let remaining = active.map { max(snapshot.settings.minFocusMinutes, $0.remainingSeconds(at: Date()) / 60) } ?? pendingMinutes
        pendingSwitch = nil
        run {
            try service.finishFocus()
            focusTaskId = target.isEmpty ? nil : target
            try service.startFocus(taskId: focusTaskId, minutes: remaining)
        }
        persistSelection()
        rescheduleNotification()
        if route == .picker { route = .tasks }
    }

    func startFocus(on id: String? = nil) {
        guard let service else { return }
        if let id { focusTaskId = id; persistSelection() }
        guard active == nil else { return }
        justCompleted = nil
        run { try service.startFocus(taskId: focusTaskId, minutes: pendingMinutes) }
        rescheduleNotification()
    }

    func togglePause() {
        guard let service else { return }
        guard let a = active else { startFocus(); return }
        run { a.status == .running ? try service.pauseFocus() : try service.resumeFocus() }
        rescheduleNotification()
    }

    func adjust(_ sign: Int) {
        let st = snapshot.settings
        let delta = sign * st.timerStepMinutes
        if active != nil, let service {
            run { try service.adjustFocus(byMinutes: delta) }
            rescheduleNotification()
        } else {
            pendingMinutes = min(st.maxFocusMinutes, max(st.minFocusMinutes, pendingMinutes + delta))
            config.pendingMinutes = pendingMinutes
            try? config.save()
        }
    }

    func finishFocus() {
        guard let service else { return }
        run { try service.finishFocus() }
        rescheduleNotification()
    }

    func resetFocus() {
        guard let service else { return }
        run { try service.resetFocus() }
        rescheduleNotification()
    }

    private func persistSelection() {
        config.selectedTaskId = focusTaskId
        try? config.save()
    }

    private func rescheduleNotification() {
        Notifier.cancelAll()
        guard snapshot.settings.notifications, let a = snapshot.active, a.status == .running else { return }
        Notifier.schedule(id: a.id, at: a.expectedEnd, title: "Focus session complete",
                          body: "\(a.plannedMinutes) minutes on “\(a.taskTitle)”", sound: snapshot.settings.sound)
    }

    // MARK: Settings

    func saveSettings(_ s: AppSettings) {
        guard let service else { return }
        run { try service.updateSettings(s) }
        if active == nil {
            pendingMinutes = min(s.maxFocusMinutes, max(s.minFocusMinutes, pendingMinutes))
        }
        rescheduleNotification()
    }

    // MARK: Assistant

    func makeProvider() -> AIProvider {
        let s = snapshot.settings
        return s.aiProvider == "anthropic" ? AnthropicProvider(model: s.aiModel) : AppleIntelligenceProvider()
    }

    func plan(_ request: String) async throws -> AIPlan {
        let snap = snapshot
        return try await AIPlanner(provider: makeProvider()).plan(request, snapshot: snap)
    }

    func apply(_ ops: [AIOperation]) {
        guard let service else { return }
        run { try AIPlanner.apply(ops, service: service) }
        if let a = snapshot.active { focusTaskId = a.taskId }
        rescheduleNotification()
    }

    // MARK: Errors

    func run(_ body: () throws -> Void) {
        do {
            try body()
            refresh()
        } catch {
            refresh()
            show(error)
        }
    }

    func show(_ error: Error) {
        Log.write("error: \(error)")
        switch error {
        case FloataskError.writeFailed, FloataskError.validationFailed:
            show(Banner(message: "Floatask couldn't save your changes.", detail: "Your existing vault data was not overwritten.", retry: true))
        case FloataskError.unreadable:
            show(Banner(message: "Some task data could not be read.", detail: "Check Tasks.md in your vault."))
        default:
            show(Banner(message: error.localizedDescription))
        }
    }

    func show(_ b: Banner) { withAnimation(.easeOut(duration: 0.15)) { banner = b } }

    func openDataFolder() {
        guard let folder = service?.layout.folder else { return }
        NSWorkspace.shared.open(folder)
    }

    func openInObsidian() {
        guard let layout = service?.layout else { return }
        let vault = layout.vault.lastPathComponent
        let file = layout.folder.lastPathComponent + "/Tasks"
        var c = URLComponents(string: "obsidian://open")!
        c.queryItems = [URLQueryItem(name: "vault", value: vault), URLQueryItem(name: "file", value: file)]
        if let url = c.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(layout.tasks)
        }
    }
}

// MARK: - Notifications

enum Notifier {
    static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    static func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func schedule(id: String, at date: Date, title: String, body: String, sound: Bool) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let interval = max(1, date.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancelAll() { center?.removeAllPendingNotificationRequests() }
}

// MARK: - File watching (FSEvents on the Task Manager folder)

final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: () -> Void

    init(url: URL, handler: @escaping () -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { me.handler() }
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, [url.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
