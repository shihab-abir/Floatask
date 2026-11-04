import Foundation

public enum SafeFile {
    /// Writes to a hidden temp file in the same directory, fsyncs, then atomically renames over the target.
    /// A crash at any point leaves either the old or the new file — never a partial one.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).floatask-\(UUID().uuidString.prefix(8)).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else {
            throw FloataskError.writeFailed(url.path)
        }
        do {
            let h = try FileHandle(forWritingTo: tmp)
            try h.write(contentsOf: data)
            try h.synchronize()
            try h.close()
            if rename(tmp.path, url.path) != 0 { throw FloataskError.writeFailed(url.path) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error is FloataskError ? error : FloataskError.writeFailed(url.path)
        }
    }

    public static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    public static func read(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            guard let s = String(data: data, encoding: .utf8) else { throw FloataskError.unreadable(url.path) }
            return s
        } catch let e as FloataskError {
            throw e
        } catch {
            throw FloataskError.unreadable(url.path)
        }
    }

    /// Copies the current file into the backup folder (at most once per `minInterval` per file)
    /// and keeps the newest `keep` copies.
    public static func backup(_ url: URL, into dir: URL, minInterval: TimeInterval = 300, keep: Int = 30) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        let existing = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(stem + "-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        if let newest = existing.first,
           let date = try? newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < minInterval {
            return
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let target = dir.appendingPathComponent("\(stem)-\(f.string(from: Date())).md")
        try? fm.copyItem(at: url, to: target)
        for old in existing.dropFirst(max(0, keep - 1)) { try? fm.removeItem(at: old) }
    }
}

/// Cross-process lock (app + CLI) held around every read-modify-write of vault files.
public final class VaultLock {
    private let fd: Int32

    public init() {
        try? FileManager.default.createDirectory(at: LocalConfig.directory, withIntermediateDirectories: true)
        fd = open(LocalConfig.directory.appendingPathComponent("vault.lock").path, O_CREAT | O_RDWR, 0o644)
    }

    deinit { if fd >= 0 { close(fd) } }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN) } }
        return try body()
    }
}

public enum FloataskError: LocalizedError, Equatable {
    case vaultMissing(String)
    case notConfigured
    case writeFailed(String)
    case unreadable(String)
    case validationFailed(String)
    case taskNotFound(String)
    case invalid(String)
    case noActiveSession

    public var errorDescription: String? {
        switch self {
        case .vaultMissing: return "Your Obsidian vault could not be found."
        case .notConfigured: return "No Obsidian vault is configured yet."
        case .writeFailed: return "Floatask couldn't save your changes. Your existing vault data was not overwritten."
        case .unreadable: return "Some task data could not be read."
        case .validationFailed: return "Floatask couldn't save your changes safely. Your existing vault data was not overwritten."
        case .taskNotFound: return "That task no longer exists."
        case .invalid(let why): return why
        case .noActiveSession: return "There is no focus session running."
        }
    }
}

/// Minimal local log for debugging (~/Library/Logs/Floatask.log).
public enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Floatask.log")

    public static func write(_ message: String) {
        let line = "\(Dates.iso(Date())) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
