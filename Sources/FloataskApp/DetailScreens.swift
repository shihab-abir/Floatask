import SwiftUI

// MARK: - Focus task picker (⌘⇧F)

struct TaskPickerView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var query = ""
    @ViewState private var index = 0
    @FocusState private var focused: Bool

    private var options: [TaskItem] {
        let open = model.visibleTasks.filter { !$0.isDone }
        guard !query.isEmpty else { return open }
        return open.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search tasks", text: $query)
                .textFieldStyle(.plain)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .focused($focused)
                .onSubmit { if options.indices.contains(index) { model.selectFocusTask(options[index].id) } }
                .onKeyPress(.downArrow) { index = min(index + 1, max(0, options.count - 1)); return .handled }
                .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                .onExitCommand { model.route = .tasks }
                .onChange(of: query) { _, _ in index = 0 }
            ScrollView {
                VStack(spacing: 1) {
                    if options.isEmpty {
                        Text(query.isEmpty ? "No open tasks." : "No matches.")
                            .foregroundStyle(Theme.secondary).padding(.top, 20)
                    }
                    ForEach(Array(options.enumerated()), id: \.element.id) { i, t in
                        Button { model.selectFocusTask(t.id) } label: {
                            HStack {
                                Text(t.title).lineLimit(1)
                                Spacer()
                                if model.focusTask?.id == t.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .padding(.leading, CGFloat(query.isEmpty ? t.depth : 0) * 16 + 8)
                            .padding(.trailing, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(i == index ? Theme.surfaceHover : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.focusTask != nil && model.active == nil {
                        Button("Clear focus task") { model.selectFocusTask(nil) }
                            .buttonStyle(QuietButtonStyle(tint: Theme.secondary))
                            .padding(.top, 6)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .onAppear { focused = true }
    }
}

// MARK: - Edit task

struct TaskEditView: View {
    @EnvironmentObject var model: AppModel
    let taskId: String
    @ViewState private var title = ""
    @ViewState private var notes = ""
    @ViewState private var hasDue = false
    @ViewState private var due = Date()
    @ViewState private var priority: Priority?
    @ViewState private var group = ""
    @ViewState private var tags = ""
    @ViewState private var loaded = false

    var body: some View {
        if let t = model.snapshot.task(taskId) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("Title") {
                        TextField("Title", text: $title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .medium))
                            .onSubmit(save)
                    }
                    field("Notes") {
                        TextEditor(text: $notes)
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 60, maxHeight: 140)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        field("Due") {
                            HStack {
                                Toggle("", isOn: $hasDue).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                if hasDue {
                                    DatePicker("", selection: $due, displayedComponents: .date)
                                        .labelsHidden().datePickerStyle(.field)
                                } else {
                                    Text("None").foregroundStyle(Theme.tertiary)
                                }
                            }
                        }
                    }
                    field("Priority") {
                        Picker("", selection: $priority) {
                            Text("None").tag(Priority?.none)
                            Text("Low").tag(Priority?.some(.low))
                            Text("Medium").tag(Priority?.some(.medium))
                            Text("High").tag(Priority?.some(.high))
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if t.depth == 0 {
                        field("Group") {
                            HStack {
                                TextField("None", text: $group).textFieldStyle(.plain)
                                if !model.groups.isEmpty {
                                    Menu {
                                        ForEach(model.groups, id: \.self) { g in Button(g) { group = g } }
                                        Button("None") { group = "" }
                                    } label: { Image(systemName: "chevron.down") }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                }
                            }
                        }
                    }
                    field("Tags") {
                        TextField("design, client", text: $tags).textFieldStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        let secs = model.focusSeconds(for: t.id)
                        Text("Focus time: \(secs > 0 ? Dates.duration(secs) : "none yet")")
                        if let c = t.createdAt { Text("Created \(c.formatted(date: .abbreviated, time: .shortened))") }
                        if let c = t.completedAt { Text("Completed \(c.formatted(date: .abbreviated, time: .shortened))") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)

                    HStack {
                        Button("Delete…") { model.pendingDelete = taskId }
                            .buttonStyle(QuietButtonStyle(tint: Theme.danger))
                        Spacer()
                        Button("Cancel") { model.route = .tasks }.buttonStyle(QuietButtonStyle())
                        Button("Save", action: save)
                            .buttonStyle(QuietButtonStyle(prominent: true, tint: Theme.accent))
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                    Button("Open Tasks.md in Obsidian") { model.openInObsidian() }
                        .buttonStyle(QuietButtonStyle(tint: Theme.secondary))
                        .font(.system(size: 11))
                }
                .padding(12)
            }
            .scrollIndicators(.never)
            .onAppear { load(t) }
        } else {
            Text("That task no longer exists.").foregroundStyle(Theme.secondary).padding()
        }
    }

    private func field<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Theme.label(label)
            content()
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }

    private func load(_ t: TaskItem) {
        guard !loaded else { return }
        loaded = true
        title = t.title
        notes = t.notes
        hasDue = t.due != nil
        due = t.due.flatMap { Dates.parseDay($0) } ?? Date()
        priority = t.priority
        group = t.group ?? ""
        tags = t.tags.joined(separator: ", ")
    }

    private func save() {
        guard let t = model.snapshot.task(taskId) else { return }
        let tagList = tags.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        let g = group.trimmingCharacters(in: .whitespaces)
        var patch = TaskPatch(title: title, notes: notes, priority: .some(priority),
                              due: .some(hasDue ? Dates.dayKey(due) : nil), tags: tagList)
        if t.depth == 0 && (t.group ?? "") != g { patch.group = .some(g.isEmpty ? nil : g) }
        model.update(taskId, patch)
        if model.banner == nil { model.route = .tasks }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var tab = 0
    @ViewState private var completed: [TaskItem] = []

    var body: some View {
        VStack(spacing: 10) {
            totals
            Picker("", selection: $tab) {
                Text("Sessions").tag(0)
                Text("Completed").tag(1)
                Text("By task").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    switch tab {
                    case 0: sessions
                    case 1: completedList
                    default: byTask
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .padding(12)
        .onAppear { completed = model.service?.completedTasks() ?? [] }
        .onChange(of: model.snapshot.tasks) { _, _ in completed = model.service?.completedTasks() ?? [] }
    }

    private var totals: some View {
        let cal = Calendar.current
        let today = model.snapshot.focusTotal(since: cal.startOfDay(for: model.now), now: model.now)
        let week = model.snapshot.focusTotal(since: cal.dateInterval(of: .weekOfYear, for: model.now)?.start ?? model.now, now: model.now)
        return HStack(spacing: 8) {
            stat("Today focused", Dates.duration(today))
            stat("This week", Dates.duration(week))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Theme.label(label)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    @ViewBuilder
    private var sessions: some View {
        let all = model.snapshot.sessions
        if all.isEmpty {
            empty("No focus sessions yet.", "Start a focus session to build your history.")
        } else {
            let byDay = Dictionary(grouping: all.prefix(400)) { Dates.dayKey($0.startedAt) }
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                let items = byDay[day]!.sorted { $0.startedAt > $1.startedAt }
                let total = items.reduce(0) { $0 + ($1.status.isActive ? $1.elapsedSeconds(at: model.now) : $1.actualSeconds) }
                dayHeader(day, trailing: Dates.duration(total))
                ForEach(items) { s in
                    let secs = s.status.isActive ? s.elapsedSeconds(at: model.now) : s.actualSeconds
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Dates.duration(secs))
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .frame(width: 52, alignment: .leading)
                            .foregroundStyle(s.status.isActive ? Theme.focus : Theme.text)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.taskTitle).lineLimit(2)
                            Text(sessionMeta(s)).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func sessionMeta(_ s: FocusSession) -> String {
        var parts = [s.startedAt.formatted(date: .omitted, time: .shortened)]
        switch s.status {
        case .completed: parts.append("completed")
        case .endedEarly: parts.append("ended early")
        case .interrupted: parts.append("interrupted")
        case .running: parts.append("in progress")
        case .paused: parts.append("paused")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var completedList: some View {
        if completed.isEmpty {
            empty("Nothing completed yet.", "Checked tasks appear here, grouped by day.")
        } else {
            let byDay = Dictionary(grouping: completed) { $0.completedAt.map { Dates.dayKey($0) } ?? "Unknown" }
            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                dayHeader(day, trailing: "\(byDay[day]!.count)")
                ForEach(byDay[day]!) { t in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                        Text(t.title).foregroundStyle(Theme.secondary)
                        Spacer()
                        if let g = t.group { Text(g).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary) }
                    }
                    .padding(.leading, CGFloat(t.depth) * 14)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var byTask: some View {
        let sessions = model.snapshot.sessions.filter { !$0.status.isActive }
        if sessions.isEmpty {
            empty("No focus sessions yet.", "Time you focus on each task adds up here.")
        } else {
            let grouped = Dictionary(grouping: sessions) { $0.taskId ?? "—" }
            let rows = grouped.map { (key, list) in
                (title: model.snapshot.task(key)?.title ?? list.first!.taskTitle,
                 total: list.reduce(0) { $0 + $1.actualSeconds }, count: list.count, key: key)
            }.sorted { $0.total > $1.total }
            let maxTotal = max(1, rows.first?.total ?? 1)
            ForEach(rows, id: \.key) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.title).lineLimit(1)
                        Spacer()
                        Text(Dates.duration(r.total)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    GeometryReader { g in
                        Capsule().fill(Theme.accent.opacity(0.7)).frame(width: g.size.width * CGFloat(r.total) / CGFloat(maxTotal))
                    }
                    .frame(height: 3)
                    Text("\(r.count) session\(r.count == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func dayHeader(_ day: String, trailing: String) -> some View {
        HStack {
            Theme.label(dayLabel(day))
            Spacer()
            Text(trailing).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
        }
        .padding(.top, 10)
    }

    private func dayLabel(_ day: String) -> String {
        guard let d = Dates.parseDay(day) else { return day }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func empty(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 16)
    }
}

// MARK: - Assistant

struct AssistantView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var request = ""
    @ViewState private var working = false
    @ViewState private var plan: AIPlan?
    @ViewState private var included: Set<Int> = []
    @ViewState private var error: String?
    @ViewState private var lastRequest = ""
    @FocusState private var focused: Bool

    var body: some View {
        let provider = model.makeProvider()
        let availability = provider.availability()
        VStack(alignment: .leading, spacing: 10) {
            if !model.snapshot.settings.aiEnabled {
                note("The assistant is turned off.", action: ("Open Settings", { model.route = .settings }))
            } else if case .unavailable(let why) = availability {
                note(why, action: ("Settings", { model.route = .settings }))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: provider.isLocal ? "lock.fill" : "network")
                    Text(provider.isLocal ? "Runs on this Mac — nothing leaves your computer"
                                          : "Sends your request and open tasks to \(provider.displayName)")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.tertiary)

                HStack(alignment: .bottom, spacing: 6) {
                    TextField("Ask or tell me what to change…", text: $request, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { send() }
                        .disabled(working)
                    if working {
                        ProgressView().controlSize(.small)
                    } else {
                        IconButton(symbol: "arrow.up.circle.fill", help: "Send (↩)", size: 16, tint: Theme.accent) { send() }
                            .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))

                if plan == nil && error == nil && !working { suggestions }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let error { errorView(error) }
                        if let plan { planView(plan) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .onAppear { focused = true }
        .onChange(of: model.focusAssistantField) { _, _ in focused = true }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Theme.label("Try")
            ForEach(suggestionList, id: \.self) { s in
                Button { request = s; send() } label: {
                    Text(s).font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.leading)
                }
                .buttonStyle(QuietButtonStyle(tint: Theme.secondary))
                .padding(.leading, -12)
            }
        }
    }

    private var suggestionList: [String] {
        var list = ["What should I work on next?", "How did I spend my time today?"]
        if let t = model.focusTask ?? model.snapshot.nextTask() { list.append("Break “\(t.title)” into smaller tasks") }
        list.append("Remind me to send the invoice on Friday")
        return list
    }

    private func planView(_ plan: AIPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(plan.reply).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if !plan.operations.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.operations.enumerated()), id: \.offset) { i, op in
                        Button {
                            if included.contains(i) { included.remove(i) } else { included.insert(i) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Checkbox(checked: included.contains(i)).scaleEffect(0.85)
                                Text(AIPlanner.describe(op, snapshot: model.snapshot))
                                    .font(.system(size: 12))
                                    .foregroundStyle(op.isDestructive ? Theme.danger : Theme.text)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                HStack {
                    Spacer()
                    Button("Discard") { self.plan = nil }.buttonStyle(QuietButtonStyle())
                    Button("Apply \(included.count == plan.operations.count ? "" : "\(included.count) ")changes") {
                        let ops = plan.operations.enumerated().filter { included.contains($0.offset) }.map(\.element)
                        model.apply(ops)
                        self.plan = nil
                        request = ""
                        if model.banner == nil { model.route = .tasks }
                    }
                    .buttonStyle(QuietButtonStyle(prominent: true, tint: Theme.accent))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(included.isEmpty)
                }
            }
            if !plan.rejected.isEmpty {
                Text("Skipped \(plan.rejected.count) suggestion(s) that didn't match your tasks.")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            HStack(spacing: 0) {
                Button("Try again") { request = lastRequest; send() }.buttonStyle(QuietButtonStyle())
                Button("Add as a task instead") {
                    let due = NaturalDate.find(in: lastRequest)
                    var title = lastRequest
                    if let due { title.removeSubrange(due.range) }
                    if let service = model.service {
                        model.run { try service.addTask(title: title, due: due?.day) }
                    }
                    error = nil
                    request = ""
                }
                .buttonStyle(QuietButtonStyle())
            }
            .padding(.leading, -12)
        }
    }

    private func note(_ text: String, action: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Button(action.0, action: action.1).buttonStyle(QuietButtonStyle(tint: Theme.accent)).padding(.leading, -12)
        }
    }

    private func send() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !working else { return }
        working = true
        error = nil
        plan = nil
        lastRequest = text
        Task { @MainActor in
            do {
                let p = try await model.plan(text)
                plan = p
                // Destructive operations start unticked unless the user allowed them in Settings.
                included = Set(p.operations.indices.filter { !p.operations[$0].isDestructive || !model.snapshot.settings.aiConfirmDestructive })
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - Collapsed floating button

struct PillView: View {
    @EnvironmentObject var model: AppModel
    static let size = NSSize(width: 118, height: 40)

    var body: some View {
        let p = model.progress
        let a = model.active
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Theme.border, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: ringValue(p: p, a: a))
                    .stroke(a?.status == .running ? Theme.focus : Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            if let a {
                if a.status == .paused { Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(Theme.secondary) }
                Text(Dates.clock(a.remainingSeconds(at: model.now)))
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(a.status == .running ? Theme.focus : Theme.secondary)
            } else if p.total == 0 {
                Text("Tasks").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
            } else {
                Text("\(p.done)/\(p.total)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.text)
            }
        }
        .frame(width: PillView.size.width, height: PillView.size.height)
        .background(Capsule().fill(Theme.surface))
        .overlay(Capsule().strokeBorder(Theme.border))
        .help("Click to open Floatask · drag to move")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a.map { "Focus timer \(Dates.clock($0.remainingSeconds(at: model.now))) remaining. Open Floatask" } ?? "\(p.done) of \(p.total) tasks done. Open Floatask")
    }

    private func ringValue(p: (done: Int, total: Int), a: FocusSession?) -> CGFloat {
        if let a, a.plannedSeconds > 0 { return CGFloat(a.elapsedSeconds(at: model.now)) / CGFloat(a.plannedSeconds) }
        return p.total == 0 ? 0 : CGFloat(p.done) / CGFloat(p.total)
    }
}
