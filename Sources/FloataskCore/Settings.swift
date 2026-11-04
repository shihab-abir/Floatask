import Foundation

/// Settings.md in the vault: user-facing preferences as YAML frontmatter (flat key: value).
public enum SettingsDocument {
    public static func parse(_ text: String) -> AppSettings {
        var s = AppSettings()
        let doc = TasksDocument.parse(text)
        func v(_ k: String) -> String? { doc.frontmatterValue(k).map { SessionsDocument.unquote($0) } }
        func int(_ k: String) -> Int? { v(k).flatMap(Int.init) }
        func bool(_ k: String) -> Bool? { v(k).map { ["true", "yes", "on", "1"].contains($0.lowercased()) } }
        if let x = int("default_focus_minutes") { s.defaultFocusMinutes = x }
        if let x = int("timer_step_minutes") { s.timerStepMinutes = max(1, x) }
        if let x = int("min_focus_minutes") { s.minFocusMinutes = max(1, x) }
        if let x = int("max_focus_minutes") { s.maxFocusMinutes = max(s.minFocusMinutes, x) }
        if let x = bool("sound") { s.sound = x }
        if let x = bool("notifications") { s.notifications = x }
        if let x = bool("completing_task_stops_focus") { s.completingTaskStopsFocus = x }
        if let x = v("theme"), ["system", "light", "dark"].contains(x) { s.theme = x }
        if let x = v("opacity").flatMap(Double.init) { s.opacity = min(1, max(0.4, x)) }
        if let x = bool("ai_enabled") { s.aiEnabled = x }
        if let x = v("ai_provider"), ["apple", "anthropic"].contains(x) { s.aiProvider = x }
        if let x = v("ai_model") { s.aiModel = x }
        if let x = bool("ai_confirm_destructive") { s.aiConfirmDestructive = x }
        s.defaultFocusMinutes = min(s.maxFocusMinutes, max(s.minFocusMinutes, s.defaultFocusMinutes))
        return s
    }

    public static func serialize(_ s: AppSettings) -> String {
        """
        ---
        schema_version: 1
        type: task_manager_settings
        default_focus_minutes: \(s.defaultFocusMinutes)
        timer_step_minutes: \(s.timerStepMinutes)
        min_focus_minutes: \(s.minFocusMinutes)
        max_focus_minutes: \(s.maxFocusMinutes)
        sound: \(s.sound)
        notifications: \(s.notifications)
        completing_task_stops_focus: \(s.completingTaskStopsFocus)
        theme: \(s.theme)
        opacity: \(String(format: "%.2f", s.opacity))
        ai_enabled: \(s.aiEnabled)
        ai_provider: \(s.aiProvider)
        ai_model: \(SessionsDocument.quote(s.aiModel))
        ai_confirm_destructive: \(s.aiConfirmDestructive)
        ---

        # Task Manager Settings

        These values are read by Floatask. Edit them here or in the app's settings (⋯ → Settings).
        API keys are never stored in this file — they live in the macOS Keychain.

        """
    }
}

/// Machine-local configuration (not in the vault): which vault to use and window state.
/// Stored at ~/Library/Application Support/Floatask/config.json. Disposable.
public struct LocalConfig: Codable, Equatable {
    public var vaultPath: String?
    public var folderName: String = "Task Manager"
    public var panelFrame: [Double]?     // x, y, w, h
    public var pillFrame: [Double]?
    public var minimized: Bool = false
    public var selectedTaskId: String?
    public var pendingMinutes: Int?
    public var collapsedGroups: [String] = []
    public var listView: String?         // ListView raw value

    public init() {}

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Floatask", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Where config lived when the app was called Taskflow (before 0.2.0); read once, then saved to the new place.
    static var legacyFileURL: URL {
        directory.deletingLastPathComponent().appendingPathComponent("Taskflow/config.json")
    }

    public static func load() -> LocalConfig {
        guard let data = (try? Data(contentsOf: fileURL)) ?? (try? Data(contentsOf: legacyFileURL)),
              let c = try? JSONDecoder().decode(LocalConfig.self, from: data) else { return LocalConfig() }
        return c
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: LocalConfig.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SafeFile.write(try enc.encode(self), to: LocalConfig.fileURL)
    }

    public var layout: VaultLayout? {
        guard let vaultPath, !vaultPath.isEmpty else { return nil }
        return VaultLayout(vault: URL(fileURLWithPath: vaultPath, isDirectory: true), folderName: folderName)
    }
}

public struct VaultLayout: Sendable {
    public let vault: URL
    public let folder: URL

    public init(vault: URL, folderName: String = "Task Manager") {
        self.vault = vault
        self.folder = vault.appendingPathComponent(folderName, isDirectory: true)
    }

    public var tasks: URL { folder.appendingPathComponent("Tasks.md") }
    public var sessions: URL { folder.appendingPathComponent("Sessions.md") }
    public var settings: URL { folder.appendingPathComponent("Settings.md") }
    public var archiveDir: URL { folder.appendingPathComponent("Archive", isDirectory: true) }
    public var backupDir: URL { folder.appendingPathComponent(".backups", isDirectory: true) }

    public func archive(month: String) -> URL { archiveDir.appendingPathComponent("\(month).md") }

    /// Every path the app writes must be inside the managed folder.
    public func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }
}
