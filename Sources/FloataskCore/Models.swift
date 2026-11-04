import Foundation

/// How the task list is arranged. Stored per machine in LocalConfig.
public enum ListView: String, CaseIterable, Codable, Sendable {
    case upNext = "up_next"    // the user's own sequence, set by dragging
    case groups
    case priority

    public var title: String {
        switch self {
        case .upNext: return "Up next"
        case .groups: return "Groups"
        case .priority: return "Priority"
        }
    }
}

public enum Priority: String, CaseIterable, Codable, Sendable {
    case high, medium, low

    public var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

/// A task as the app sees it: a parsed checkbox line from Tasks.md plus derived tree info.
public struct TaskItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var notes: String
    public var isDone: Bool
    public var priority: Priority?
    public var due: String?            // YYYY-MM-DD
    public var tags: [String]
    public var group: String?          // the `## Heading` the task lives under
    public var createdAt: Date?
    public var completedAt: Date?
    public var parentId: String?
    public var depth: Int
    public var hasPersistedId: Bool
    public var order: Int?             // position in the "Up next" list (top-level tasks only)

    public init(id: String, title: String, notes: String = "", isDone: Bool = false,
                priority: Priority? = nil, due: String? = nil, tags: [String] = [],
                group: String? = nil, createdAt: Date? = nil, completedAt: Date? = nil,
                parentId: String? = nil, depth: Int = 0, hasPersistedId: Bool = true, order: Int? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isDone = isDone
        self.priority = priority
        self.due = due
        self.tags = tags
        self.group = group
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.parentId = parentId
        self.depth = depth
        self.hasPersistedId = hasPersistedId
        self.order = order
    }
}

/// Fields that may be changed on an existing task. `nil` means "leave unchanged";
/// the nested optionals allow clearing a value (`.some(nil)`).
public struct TaskPatch: Sendable {
    public var title: String?
    public var notes: String?
    public var priority: Priority??
    public var due: String??
    public var tags: [String]?
    public var group: String??

    public init(title: String? = nil, notes: String? = nil, priority: Priority?? = nil,
                due: String?? = nil, tags: [String]? = nil, group: String?? = nil) {
        self.title = title
        self.notes = notes
        self.priority = priority
        self.due = due
        self.tags = tags
        self.group = group
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case running
    case paused
    case completed      // timer reached zero
    case endedEarly = "ended_early"   // user pressed Finish before zero
    case interrupted    // reset, or found abandoned after a crash

    public var isActive: Bool { self == .running || self == .paused }
}

public struct FocusSession: Identifiable, Equatable, Sendable {
    public var id: String
    public var taskId: String?
    public var taskTitle: String
    public var startedAt: Date
    public var endedAt: Date?
    public var plannedMinutes: Int
    public var actualSeconds: Int
    public var status: SessionStatus
    public var pausedSeconds: Int       // total time spent paused (completed pauses)
    public var pausedAt: Date?          // set while paused
    public var note: String?
    public var extra: [(String, String)] = []   // unknown keys, preserved on rewrite

    public init(id: String, taskId: String?, taskTitle: String, startedAt: Date,
                endedAt: Date? = nil, plannedMinutes: Int, actualSeconds: Int = 0,
                status: SessionStatus, pausedSeconds: Int = 0, pausedAt: Date? = nil,
                note: String? = nil) {
        self.id = id
        self.taskId = taskId
        self.taskTitle = taskTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.plannedMinutes = plannedMinutes
        self.actualSeconds = actualSeconds
        self.status = status
        self.pausedSeconds = pausedSeconds
        self.pausedAt = pausedAt
        self.note = note
    }

    public static func == (a: FocusSession, b: FocusSession) -> Bool {
        a.id == b.id && a.taskId == b.taskId && a.taskTitle == b.taskTitle
            && a.startedAt == b.startedAt && a.endedAt == b.endedAt
            && a.plannedMinutes == b.plannedMinutes && a.actualSeconds == b.actualSeconds
            && a.status == b.status && a.pausedSeconds == b.pausedSeconds
            && a.pausedAt == b.pausedAt && a.note == b.note
    }

    // MARK: Timer maths — everything derives from timestamps, never from a counter.

    public var plannedSeconds: Int { plannedMinutes * 60 }

    /// Seconds of real focus so far (excludes paused time).
    public func elapsedSeconds(at now: Date) -> Int {
        if !status.isActive { return actualSeconds }
        var paused = Double(pausedSeconds)
        if status == .paused, let p = pausedAt { paused += now.timeIntervalSince(p) }
        let e = now.timeIntervalSince(startedAt) - paused
        return max(0, Int(e.rounded(.down)))
    }

    public func remainingSeconds(at now: Date) -> Int {
        max(0, plannedSeconds - elapsedSeconds(at: now))
    }

    /// Wall-clock moment the timer hits zero if it keeps running.
    public var expectedEnd: Date {
        startedAt.addingTimeInterval(TimeInterval(plannedSeconds + pausedSeconds))
    }
}

public struct AppSettings: Equatable, Sendable {
    public var defaultFocusMinutes = 25
    public var timerStepMinutes = 5
    public var minFocusMinutes = 5
    public var maxFocusMinutes = 120
    public var sound = true
    public var notifications = true
    public var completingTaskStopsFocus = true
    public var theme = "system"          // system | light | dark
    public var opacity = 1.0
    public var aiEnabled = true
    public var aiProvider = "apple"      // apple | anthropic
    public var aiModel = ""
    public var aiConfirmDestructive = true

    public init() {}
}
