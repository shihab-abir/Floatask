import Foundation

/// One checkbox line in Tasks.md (or an archive file), plus the note lines indented under it.
///
/// Canonical form (see docs/FORMAT.md):
///
///     - [ ] Title · due 2026-10-02 · high #tag <!-- id:t_20260929_ab12 created:2026-09-29T10:10:00+06:00 -->
///
/// Lines that are not modified by the app are written back byte-for-byte (`raw`).
public struct TaskLine: Equatable {
    public internal(set) var id: String
    public internal(set) var hasPersistedId: Bool
    public var indent: String
    var bullet: String
    var mark: Character
    public private(set) var title: String
    public private(set) var due: String?
    public private(set) var priority: Priority?
    public private(set) var tags: [String]
    private(set) var meta: [(key: String, value: String)]
    var noteLines: [String]
    var raw: String?

    public static func == (a: TaskLine, b: TaskLine) -> Bool {
        a.id == b.id && a.indent == b.indent && a.mark == b.mark && a.title == b.title
            && a.due == b.due && a.priority == b.priority && a.tags == b.tags
            && a.meta.map { "\($0.key)=\($0.value)" } == b.meta.map { "\($0.key)=\($0.value)" }
            && a.noteLines == b.noteLines
    }

    public init(id: String, title: String, indent: String = "", done: Bool = false,
                due: String? = nil, priority: Priority? = nil, tags: [String] = []) {
        self.id = id
        self.hasPersistedId = true
        self.indent = indent
        self.bullet = "-"
        self.mark = done ? "x" : " "
        self.title = title
        self.due = due
        self.priority = priority
        self.tags = tags
        self.meta = []
        self.noteLines = []
        self.raw = nil
    }

    public var isDone: Bool { mark == "x" || mark == "X" }
    public var indentWidth: Int { TaskLine.width(of: indent) }

    static func width(of indent: String) -> Int {
        indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    public func metaValue(_ key: String) -> String? { meta.first { $0.key == key }?.value }

    public var createdAt: Date? { metaValue("created").flatMap(Dates.parseISO) }
    public var completedAt: Date? { metaValue("done").flatMap(Dates.parseISO) }

    public var notes: String {
        noteLines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
    }

    // MARK: Mutation (each marks the line dirty so it gets re-serialised)

    mutating func setMeta(_ key: String, _ value: String?) {
        raw = nil
        if let i = meta.firstIndex(where: { $0.key == key }) {
            if let value { meta[i].value = value } else { meta.remove(at: i) }
        } else if let value {
            meta.append((key, value))
        }
    }

    mutating func setDone(_ done: Bool, at date: Date) {
        guard done != isDone else { return }
        raw = nil
        mark = done ? "x" : " "
        setMeta("done", done ? Dates.iso(date) : nil)
    }

    mutating func setTitle(_ t: String) { raw = nil; title = TaskLine.clean(t) }
    mutating func setDue(_ d: String?) { raw = nil; due = d }
    mutating func setPriority(_ p: Priority?) { raw = nil; priority = p }
    mutating func setTags(_ t: [String]) { raw = nil; tags = t.map(TaskLine.cleanTag).filter { !$0.isEmpty } }

    mutating func setNotes(_ text: String) {
        raw = nil
        let childIndent = indent + (indent.contains(" ") && !indent.contains("\t") ? "    " : "\t")
        noteLines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { childIndent + $0 }
    }

    mutating func reindent(from oldBase: String, to newBase: String) {
        let strip: (String) -> String = { s in s.hasPrefix(oldBase) ? String(s.dropFirst(oldBase.count)) : String(s.drop { $0 == " " || $0 == "\t" }) }
        indent = newBase + strip(indent)
        noteLines = noteLines.map { newBase + strip($0) }
        raw = nil
    }

    mutating func assignId(_ newId: String) {
        id = newId
        hasPersistedId = true
        raw = nil
    }

    // MARK: Parsing & serialising

    static let lineRegex = try! NSRegularExpression(pattern: #"^([ \t]*)([-*+]) \[(.)\](?: (.*))?$"#)
    static let commentRegex = try! NSRegularExpression(pattern: #"\s*<!--(.*?)-->\s*$"#)
    static let tagRegex = try! NSRegularExpression(pattern: #"(?:^|\s)#([\p{L}_][\p{L}\p{N}_/\-]*)"#)
    static let dueRegex = try! NSRegularExpression(pattern: #"^due:?\s+(\d{4}-\d{2}-\d{2})$"#, options: [.caseInsensitive])

    static func parse(_ line: String) -> TaskLine? {
        let ns = line as NSString
        guard let m = lineRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: m.range(at: 1))
        let bullet = ns.substring(with: m.range(at: 2))
        let mark = Character(ns.substring(with: m.range(at: 3)))
        var text = m.range(at: 4).location == NSNotFound ? "" : ns.substring(with: m.range(at: 4))

        var meta: [(String, String)] = []
        var id: String?
        let tns = text as NSString
        if let c = commentRegex.firstMatch(in: text, range: NSRange(location: 0, length: tns.length)) {
            let body = tns.substring(with: c.range(at: 1))
            for token in body.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                guard let colon = token.firstIndex(of: ":") else { continue }
                let key = String(token[..<colon])
                let value = decode(String(token[token.index(after: colon)...]))
                if key == "id" { id = value } else { meta.append((key, value)) }
            }
            text = tns.substring(to: c.range.location)
        }

        // Tags anywhere in the text.
        var tags: [String] = []
        let textNS = text as NSString
        for tm in tagRegex.matches(in: text, range: NSRange(location: 0, length: textNS.length)).reversed() {
            tags.insert(textNS.substring(with: tm.range(at: 1)), at: 0)
        }
        if !tags.isEmpty {
            text = tagRegex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: textNS.length), withTemplate: "")
        }

        // " · " separated metadata segments after the title.
        let segments = text.components(separatedBy: " · ")
        var titleParts = [segments[0]]
        var due: String?
        var priority: Priority?
        for seg in segments.dropFirst() {
            let s = seg.trimmingCharacters(in: .whitespaces)
            let sns = s as NSString
            if let dm = dueRegex.firstMatch(in: s, range: NSRange(location: 0, length: sns.length)),
               Dates.isValidDay(sns.substring(with: dm.range(at: 1))) {
                due = sns.substring(with: dm.range(at: 1))
            } else if let p = Priority(rawValue: s.lowercased().replacingOccurrences(of: "priority ", with: "")) {
                priority = p
            } else if !s.isEmpty {
                titleParts.append(s)
            }
        }

        var t = TaskLine(id: id ?? "", title: clean(titleParts.joined(separator: " · ")), indent: indent,
                         due: due, priority: priority, tags: tags)
        t.bullet = bullet
        t.mark = mark
        t.meta = meta
        t.hasPersistedId = id != nil && !(id!.isEmpty)
        t.raw = line
        return t
    }

    func serialize() -> [String] {
        if let raw { return [raw] + noteLines }
        var s = indent + bullet + " [" + String(mark) + "] " + title
        if let due { s += " · due " + due }
        if let priority { s += " · " + priority.rawValue }
        for tag in tags { s += " #" + tag }
        var comment = "id:" + TaskLine.encode(id)
        for (k, v) in meta { comment += " " + k + ":" + TaskLine.encode(v) }
        s += " <!-- " + comment + " -->"
        return [s] + noteLines
    }

    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .replacingOccurrences(of: " · ", with: " - ")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    static func cleanTag(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).replacingOccurrences(of: " ", with: "-")
    }

    static func encode(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: ">", with: "%3E")
    }

    static func decode(_ s: String) -> String { s.removingPercentEncoding ?? s }
}

/// A parsed Markdown task file. Keeps every line it does not understand so that
/// writing it back never loses the user's own content.
public struct TasksDocument {
    enum Block {
        case heading(level: Int, text: String, raw: String)
        case task(TaskLine)
        case other(String)
    }

    var frontmatter: [String]   // lines between the --- fences (exclusive)
    var blocks: [Block]

    static let headingRegex = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*?)\s*$"#)

    init(frontmatter: [String], blocks: [Block]) {
        self.frontmatter = frontmatter
        self.blocks = blocks
    }

    public static func empty(type: String, title: String) -> TasksDocument {
        TasksDocument(frontmatter: ["schema_version: 1", "type: \(type)"],
                      blocks: [.other(""), .heading(level: 1, text: title, raw: "# \(title)"), .other("")])
    }

    // MARK: Parse / serialise

    public static func parse(_ text: String) -> TasksDocument {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var front: [String] = []
        var i = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            front = Array(lines[1..<end])
            i = end + 1
        }
        var blocks: [Block] = []
        var seenIds = Set<String>()
        var titleCounts: [String: Int] = [:]
        while i < lines.count {
            let line = lines[i]
            if var task = TaskLine.parse(line) {
                i += 1
                // Indented, non-blank, non-task, non-heading lines under a task are its notes.
                while i < lines.count {
                    let next = lines[i]
                    let lead = String(next.prefix { $0 == " " || $0 == "\t" })
                    if next.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    if TaskLine.width(of: lead) <= task.indentWidth { break }
                    if TaskLine.parse(next) != nil { break }
                    task.noteLines.append(next)
                    i += 1
                }
                if !task.hasPersistedId || seenIds.contains(task.id) {
                    // Missing or duplicated id: give it a deterministic temporary id until the next write.
                    let n = titleCounts[task.title, default: 0]
                    titleCounts[task.title] = n + 1
                    task.id = "tmp_" + fnv(task.title + "#\(n)")
                    task.hasPersistedId = false
                }
                seenIds.insert(task.id)
                blocks.append(.task(task))
                continue
            }
            let ns = line as NSString
            if let m = headingRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                blocks.append(.heading(level: m.range(at: 1).length, text: ns.substring(with: m.range(at: 2)), raw: line))
            } else {
                blocks.append(.other(line))
            }
            i += 1
        }
        return TasksDocument(frontmatter: front, blocks: blocks)
    }

    public func serialize() -> String {
        var out: [String] = []
        if !frontmatter.isEmpty { out.append("---"); out += frontmatter; out.append("---") }
        for b in blocks {
            switch b {
            case .heading(_, _, let raw): out.append(raw)
            case .task(let t): out += t.serialize()
            case .other(let s): out.append(s)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public func frontmatterValue(_ key: String) -> String? {
        for line in frontmatter {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: Queries

    public var taskLines: [TaskLine] {
        blocks.compactMap { if case .task(let t) = $0 { return t } else { return nil } }
    }

    /// Flattened tasks with group, parent and depth resolved from indentation.
    public func items() -> [TaskItem] {
        var result: [TaskItem] = []
        var group: String?
        var stack: [(width: Int, id: String)] = []
        for b in blocks {
            switch b {
            case .heading(let level, let text, _):
                group = level >= 2 ? text : nil
                stack.removeAll()
            case .task(let t):
                while let last = stack.last, last.width >= t.indentWidth { stack.removeLast() }
                result.append(TaskItem(
                    id: t.id, title: t.title, notes: t.notes, isDone: t.isDone,
                    priority: t.priority, due: t.due, tags: t.tags,
                    group: t.metaValue("group") ?? group,
                    createdAt: t.createdAt, completedAt: t.completedAt,
                    parentId: stack.last?.id, depth: stack.count, hasPersistedId: t.hasPersistedId,
                    order: t.metaValue("order").flatMap { Int($0) }))
                stack.append((t.indentWidth, t.id))
            case .other(let s):
                // A blank line or paragraph at column 0 ends any nesting.
                if !s.hasPrefix(" ") && !s.hasPrefix("\t") { stack.removeAll() }
            }
        }
        return result
    }

    func index(of id: String) -> Int? {
        blocks.firstIndex { if case .task(let t) = $0 { return t.id == id } else { return false } }
    }

    public func task(_ id: String) -> TaskLine? {
        guard let i = index(of: id), case .task(let t) = blocks[i] else { return nil }
        return t
    }

    /// Block range covering a task and all its (contiguous, deeper-indented) descendants.
    func subtreeRange(at i: Int) -> Range<Int> {
        guard case .task(let root) = blocks[i] else { return i..<(i + 1) }
        var j = i + 1
        while j < blocks.count, case .task(let t) = blocks[j], t.indentWidth > root.indentWidth { j += 1 }
        return i..<j
    }

    public func descendantIds(of id: String) -> [String] {
        guard let i = index(of: id) else { return [] }
        return blocks[subtreeRange(at: i)].dropFirst().compactMap { if case .task(let t) = $0 { return t.id } else { return nil } }
    }

    // MARK: Mutation

    mutating func modify(_ id: String, _ change: (inout TaskLine) -> Void) -> Bool {
        guard let i = index(of: id), case .task(var t) = blocks[i] else { return false }
        change(&t)
        blocks[i] = .task(t)
        return true
    }

    /// Inserts a task at the end of the given group (created if needed) or under a parent.
    mutating func insert(_ line: TaskLine, group: String?, parentId: String?) {
        var line = line
        if let parentId, let pi = index(of: parentId), case .task(let parent) = blocks[pi] {
            let range = subtreeRange(at: pi)
            let unit = parent.indent.contains(" ") && !parent.indent.contains("\t") ? "    " : "\t"
            line.indent = parent.indent + unit
            line.raw = nil
            blocks.insert(.task(line), at: range.upperBound)
            return
        }
        line.indent = ""
        line.raw = nil
        let (start, end) = sectionBounds(group: group)
        guard let start else {
            // New group heading at the end of the file.
            if let last = blocks.last, case .other(let s) = last, s.isEmpty {} else { blocks.append(.other("")) }
            blocks.append(.heading(level: 2, text: group!, raw: "## \(group!)"))
            blocks.append(.other(""))
            blocks.append(.task(line))
            return
        }
        // After the last task in the section, otherwise right below the heading (and one blank line).
        var pos = start
        for k in start..<end { if case .task = blocks[k] { pos = k + 1 } }
        if pos == start {
            if pos < blocks.count, case .other(let s) = blocks[pos], s.isEmpty, start > 0 {
                pos += 1
            } else if pos > 0, case .heading = blocks[pos - 1] {
                blocks.insert(.other(""), at: pos)   // keep a blank line under the heading
                pos += 1
            }
        }
        blocks.insert(.task(line), at: pos)
    }

    /// (first index inside the section, end index). `start == nil` means the group doesn't exist yet.
    private func sectionBounds(group: String?) -> (Int?, Int) {
        if let group {
            guard let h = blocks.firstIndex(where: { if case .heading(let l, let t, _) = $0 { return l >= 2 && t == group } else { return false } }),
                  case .heading(let level, _, _) = blocks[h] else { return (nil, blocks.count) }
            let end = blocks[(h + 1)...].firstIndex { if case .heading(let l, _, _) = $0 { return l <= level } else { return false } } ?? blocks.count
            return (h + 1, end)
        }
        // Ungrouped: everything before the first `##` heading, after any `#` title.
        let end = blocks.firstIndex { if case .heading(let l, _, _) = $0 { return l >= 2 } else { return false } } ?? blocks.count
        let titleIdx = blocks[..<end].firstIndex { if case .heading(1, _, _) = $0 { return true } else { return false } }
        return ((titleIdx.map { $0 + 1 }) ?? 0, end)
    }

    /// Removes a task and its descendants, returning the removed lines.
    @discardableResult
    mutating func removeSubtree(_ id: String) -> [TaskLine] {
        guard let i = index(of: id) else { return [] }
        let r = subtreeRange(at: i)
        let removed = blocks[r].compactMap { b -> TaskLine? in if case .task(let t) = b { return t } else { return nil } }
        blocks.removeSubrange(r)
        return removed
    }

    /// Re-roots a removed subtree at column 0 and appends it to a group.
    mutating func insertSubtree(_ lines: [TaskLine], group: String?) {
        guard let root = lines.first else { return }
        let base = root.indent
        var reindented = lines.map { l -> TaskLine in var l = l; l.reindent(from: base, to: ""); return l }
        let first = reindented.removeFirst()
        insert(first, group: group, parentId: nil)
        guard var pos = index(of: first.id) else { return }
        for var l in reindented {
            pos += 1
            l.raw = nil
            blocks.insert(.task(l), at: pos)
        }
    }

    /// Gives every task without a persisted id a real one and keeps done-stamps consistent.
    /// Returns a map of temporary id → new id.
    @discardableResult
    mutating func normalize(now: Date, makeId: () -> String) -> [String: String] {
        var map: [String: String] = [:]
        for i in blocks.indices {
            guard case .task(var t) = blocks[i] else { continue }
            var changed = false
            if !t.hasPersistedId {
                let new = makeId()
                map[t.id] = new
                t.assignId(new)
                if t.metaValue("created") == nil { t.setMeta("created", Dates.iso(now)) }
                changed = true
            }
            if t.isDone && t.metaValue("done") == nil { t.setMeta("done", Dates.iso(now)); changed = true }
            if !t.isDone && t.metaValue("done") != nil { t.setMeta("done", nil); changed = true }
            if changed { blocks[i] = .task(t) }
        }
        return map
    }

    /// True when a write is needed to stamp tasks checked/unchecked outside the app.
    public var needsDoneStamps: Bool {
        taskLines.contains { ($0.isDone && $0.metaValue("done") == nil) || (!$0.isDone && $0.metaValue("done") != nil) }
    }
}

func fnv(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 36)
}
