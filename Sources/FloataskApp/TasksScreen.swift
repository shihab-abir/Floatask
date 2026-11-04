import SwiftUI

struct TasksScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FocusCard()
                    ProgressSection()
                    ListViewTabs()
                    TaskList()
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            .scrollIndicators(.never)
            .onChange(of: model.highlightedId) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

// MARK: - Focus card

struct FocusCard: View {
    @EnvironmentObject var model: AppModel

    private var running: Bool { model.active?.status == .running }
    private var paused: Bool { model.active?.status == .paused }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Theme.label(running ? "Focusing" : paused ? "Paused" : "Focus")
                Spacer()
                if let a = model.active {
                    Text("\(a.plannedMinutes) min session")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                }
            }

            if let done = model.justCompleted, model.active == nil {
                completed(done)
            } else {
                Text(Dates.clock(model.timerSeconds))
                    .font(Theme.timerFont)
                    .foregroundStyle(running ? Theme.focus : Theme.text)
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("\(model.timerSeconds / 60) minutes \(model.timerSeconds % 60) seconds \(model.active == nil ? "planned" : "remaining")")
            }

            taskSelector

            controls
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(running ? Theme.focusSoft : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(running ? Theme.focus.opacity(0.25) : Theme.border))
        .animation(.easeOut(duration: 0.2), value: running)
    }

    private func completed(_ s: FocusSession) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(Theme.accent)
            Text("\(Dates.duration(s.actualSeconds)) logged").font(.system(size: 15, weight: .semibold))
            Text("Nice work. Take a short break.").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var taskSelector: some View {
        Button {
            model.route = .picker
        } label: {
            HStack(spacing: 6) {
                if let t = model.focusTask {
                    Text(t.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("Select a task to track your focus time")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose the task you're working on (⌘⇧F)")
        .accessibilityLabel(model.focusTask.map { "Working on \($0.title). Change task" } ?? "Select a focus task")
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            stepButton(-1)
            Spacer(minLength: 0)
            if model.active == nil {
                Button { model.startFocus() } label: {
                    Label("Start", systemImage: "play.fill").font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle(prominent: true, tint: Theme.accent))
                .help("Start focus (⌘↩)")
            } else {
                IconButton(symbol: "arrow.counterclockwise", help: "Reset (sessions over a minute are kept as interrupted)") { model.resetFocus() }
                Button { model.togglePause() } label: {
                    Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle(prominent: true, tint: paused ? Theme.accent : Theme.focus))
                .help("\(paused ? "Resume" : "Pause") (⌘↩)")
                IconButton(symbol: "checkmark", help: "Finish now and log the time") { model.finishFocus() }
            }
            Spacer(minLength: 0)
            stepButton(1)
        }
    }

    private func stepButton(_ sign: Int) -> some View {
        let step = model.snapshot.settings.timerStepMinutes
        return Button { model.adjust(sign) } label: {
            Text(sign < 0 ? "−\(step)" : "+\(step)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(minWidth: 30)
        }
        .buttonStyle(QuietButtonStyle(tint: Theme.secondary))
        .help(sign < 0 ? "\(step) minutes less" : "\(step) minutes more")
        .accessibilityLabel(sign < 0 ? "Decrease by \(step) minutes" : "Increase by \(step) minutes")
    }
}

// MARK: - Progress

struct ProgressSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let p = model.progress
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Theme.label("Open tasks")
                Spacer()
                if p.total > 0 {
                    Text("\(p.done)/\(p.total)").foregroundStyle(Theme.tertiary)
                    Text("\(Int((Double(p.done) / Double(p.total) * 100).rounded()))%")
                        .fontWeight(.semibold)
                        .foregroundStyle(p.done == p.total ? Theme.accent : Theme.secondary)
                }
            }
            .font(.system(size: 11.5).monospacedDigit())

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    if p.total > 0 {
                        Capsule().fill(Theme.accent)
                            .frame(width: max(0, geo.size.width * CGFloat(p.done) / CGFloat(p.total)))
                    }
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.25), value: p.done)
            .accessibilityElement()
            .accessibilityLabel(p.total == 0 ? "No tasks" : "\(p.done) of \(p.total) tasks done")

            if p.total > 0 && p.done == p.total {
                Text("Everything is done.").font(.system(size: 11.5)).foregroundStyle(Theme.accent)
            } else if let next = model.snapshot.nextTask(now: model.now), next.id != model.focusTask?.id {
                (Text("next: ").foregroundStyle(Theme.tertiary) + Text(next.title).foregroundStyle(Theme.secondary))
                    .font(.system(size: 11.5))
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - List

/// Segmented switch between the three list arrangements (⌘1 / ⌘2 / ⌘3).
struct ListViewTabs: View {
    @EnvironmentObject var model: AppModel
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(ListView.allCases.enumerated()), id: \.element) { i, v in
                let selected = model.listView == v
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { model.setListView(v) }
                } label: {
                    Text(v.title)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.text : Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.surface)
                                    .shadow(color: .black.opacity(0.06), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "tab", in: selection)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(help(v) + " (⌘\(i + 1))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surfaceHover))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Arrange tasks")
    }

    private func help(_ v: ListView) -> String {
        switch v {
        case .upNext: return "The order you'll work in — drag tasks to rearrange"
        case .groups: return "Tasks by group"
        case .priority: return "Tasks by priority"
        }
    }
}

struct TaskList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let sections = model.sections
        VStack(alignment: .leading, spacing: 1) {
            if sections.isEmpty || sections.allSatisfy({ $0.tasks.isEmpty }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No tasks yet.").font(.system(size: 13, weight: .medium))
                    Text("Add your first task below.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .padding(.vertical, 8)
            } else if model.listView == .upNext {
                UpNextList(tasks: sections[0].tasks)
            } else {
                ForEach(sections) { section in
                    if model.listView == .groups {
                        if let g = section.title {
                            GroupHeader(group: g, count: section.tasks.filter { !$0.isDone }.count)
                        }
                    } else if let title = section.title {
                        SectionHeader(title: title, count: section.tasks.filter { !$0.isDone }.count)
                    }
                    if !(model.listView == .groups && section.title.map { model.collapsedGroups.contains($0) } ?? false) {
                        ForEach(section.tasks) { t in
                            TaskRow(task: t).id(t.id)
                            if model.addingUnder == t.id {
                                AddTaskField(parentId: t.id, placeholder: "Add subtask", depth: t.depth + 1)
                            }
                        }
                        if model.listView == .groups, let g = section.title, model.addingGroup == g {
                            AddTaskField(group: g, placeholder: "Add to \(g)", autofocus: true)
                        }
                    }
                }
            }
            AddTaskField(placeholder: "Add task")
                .padding(.top, 4)
        }
    }
}

/// "Up next": the user's own sequence. Top-level tasks (with their subtasks) are dragged to reorder;
/// the list previews the new position while dragging and saves once on drop.
struct UpNextList: View {
    @EnvironmentObject var model: AppModel
    let tasks: [TaskItem]
    @ViewState private var dragging: String?
    @ViewState private var draft: [String]?          // root ids in preview order while dragging
    private let mouseCheck = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var chunks: [[TaskItem]] {
        var result: [[TaskItem]] = []
        for t in tasks {
            if t.depth == 0 || result.isEmpty { result.append([t]) } else { result[result.count - 1].append(t) }
        }
        guard let draft else { return result }
        let byRoot = Dictionary(uniqueKeysWithValues: result.map { ($0[0].id, $0) })
        return draft.compactMap { byRoot[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !tasks.contains(where: { $0.order != nil }) && tasks.filter({ $0.depth == 0 }).count > 1 {
                Text("Drag tasks into the order you'll do them.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }
            ForEach(chunks, id: \.[0].id) { chunk in
                let root = chunk[0].id
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(chunk) { t in
                        TaskRow(task: t, reorderable: t.depth == 0).id(t.id)
                        if model.addingUnder == t.id {
                            AddTaskField(parentId: t.id, placeholder: "Add subtask", depth: t.depth + 1)
                        }
                    }
                }
                .opacity(dragging == root ? 0.35 : 1)
                .onDrag {
                    dragging = root
                    draft = chunks.map { $0[0].id }
                    return NSItemProvider(object: root as NSString)
                }
                .onDrop(of: [.text], delegate: ReorderDropDelegate(target: root, dragging: $dragging, draft: $draft, commit: commit))
            }
        }
        // Dropping in the gaps between rows still counts.
        .onDrop(of: [.text], delegate: ReorderDropDelegate(target: nil, dragging: $dragging, draft: $draft, commit: commit))
        .onReceive(mouseCheck) { _ in
            // Released outside the list: put everything back.
            if dragging != nil && NSEvent.pressedMouseButtons & 1 == 0 {
                withAnimation(.easeOut(duration: 0.15)) { dragging = nil; draft = nil }
            }
        }
    }

    private func commit() {
        guard let ids = draft else { return }
        let before = tasks.filter { $0.depth == 0 }.map(\.id)
        if ids != before || !tasks.contains(where: { $0.order != nil }) { model.reorder(ids) }
        dragging = nil
        draft = nil
    }
}

struct ReorderDropDelegate: DropDelegate {
    let target: String?
    @Binding var dragging: String?
    @Binding var draft: [String]?
    let commit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let target, let d = dragging, d != target, var ids = draft,
              let from = ids.firstIndex(of: d), let to = ids.firstIndex(of: target) else { return }
        ids.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(.easeOut(duration: 0.18)) { draft = ids }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: dragging == nil ? .forbidden : .move)
    }

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        return true
    }
}

/// Plain header for priority sections (not collapsible).
struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Theme.label(title)
            if count > 0 { Text("\(count)").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary) }
            Spacer()
        }
        .frame(height: 22)
        .padding(.leading, 6)
        .padding(.top, 8)
        .padding(.bottom, 1)
        .accessibilityAddTraits(.isHeader)
    }
}

struct GroupHeader: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let count: Int
    @ViewState private var hover = false

    var body: some View {
        let g = group
        let collapsed = model.collapsedGroups.contains(g)
        return HStack(spacing: 0) {
          Button { model.toggleGroup(g) } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .foregroundStyle(Theme.tertiary)
                Theme.label(g)
                if collapsed && count > 0 {
                    Text("\(count)").font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("\(g) group, \(collapsed ? "collapsed" : "expanded")")
          if hover {
              IconButton(symbol: "plus", help: "Add a task to \(g)", size: 10) {
                  if collapsed { model.toggleGroup(g) }
                  model.addingGroup = g
              }
          }
        }
        .frame(height: 22)
        .padding(.top, 8)
        .padding(.bottom, 1)
        .onHover { hover = $0 }
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: TaskItem
    var reorderable = false
    @ViewState private var hover = false

    private var isFocus: Bool { model.focusTask?.id == task.id }
    private var isHighlighted: Bool { model.highlightedId == task.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { model.toggle(task.id) } label: {
                Checkbox(checked: task.isDone)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark “\(task.title)” as not done" : "Complete “\(task.title)”")
            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 }

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13, weight: isFocus ? .semibold : .regular))
                    .foregroundStyle(task.isDone ? Theme.tertiary : Theme.text)
                    .strikethrough(task.isDone, color: Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let meta = metaLine { meta }
            }
            Spacer(minLength: 4)
            if reorderable && hover {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .help("Drag to reorder · ⌥↑ / ⌥↓")
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 }
                    .accessibilityHidden(true)
            }
            if (hover || isHighlighted) && !task.isDone {
                IconButton(symbol: "scope", help: isFocus ? "Current focus task" : "Focus on this task (F)", size: 12,
                           tint: isFocus ? Theme.focus : Theme.tertiary) {
                    model.selectFocusTask(task.id)
                }
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 }
            }
        }
        .padding(.vertical, 5)
        .padding(.leading, CGFloat(task.depth) * 20 + 6)
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted ? Theme.surfaceHover : (hover ? Theme.surface : .clear))
        )
        .overlay(alignment: .leading) {
            if isFocus {
                Capsule().fill(model.active != nil ? Theme.focus : Theme.accent).frame(width: 3, height: 16)
                    .padding(.leading, CGFloat(task.depth) * 20)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { model.route = .edit(task.id) }
        .onTapGesture { model.highlightedId = task.id }
        .contextMenu { TaskMenu(task: task) }
        .animation(.easeOut(duration: 0.15), value: task.isDone)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private var metaLine: Text? {
        var parts: [Text] = []
        if let due = task.due {
            let label = Dates.dueLabel(due, now: model.now)
            let overdue = !task.isDone && (Dates.parseDay(due).map { $0 < Calendar.current.startOfDay(for: model.now) } ?? false)
            parts.append(Text(label).foregroundColor(overdue ? Theme.danger : Theme.tertiary))
        }
        if let p = task.priority, p != .low, !task.isDone {
            parts.append(Text(p == .high ? "High" : "Medium").foregroundColor(p == .high ? Theme.focus : Theme.tertiary))
        }
        let kids = model.snapshot.children(of: task.id)
        if !kids.isEmpty {
            parts.append(Text("\(kids.filter(\.isDone).count)/\(kids.count)").foregroundColor(Theme.tertiary))
        }
        let secs = model.focusSeconds(for: task.id)
        if secs >= 60 { parts.append(Text("◷ " + Dates.duration(secs)).foregroundColor(Theme.tertiary)) }
        if !task.tags.isEmpty { parts.append(Text(task.tags.map { "#" + $0 }.joined(separator: " ")).foregroundColor(Theme.tertiary)) }
        if !task.notes.isEmpty { parts.append(Text(Image(systemName: "text.alignleft")).foregroundColor(Theme.tertiary)) }
        guard !parts.isEmpty else { return nil }
        var out = parts[0]
        for p in parts.dropFirst() { out = out + Text("  ·  ").foregroundColor(Theme.tertiary.opacity(0.6)) + p }
        return out.font(.system(size: 11))
    }
}

struct Checkbox: View {
    let checked: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .strokeBorder(checked ? Theme.accent : Theme.checkbox, lineWidth: 1.4)
                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(checked ? Theme.accent : .clear))
            if checked {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle().inset(by: -4))
    }
}

struct TaskMenu: View {
    @EnvironmentObject var model: AppModel
    let task: TaskItem

    var body: some View {
        if !task.isDone {
            Button("Start focus") {
                if model.active == nil { model.startFocus(on: task.id) } else { model.selectFocusTask(task.id) }
            }
            Button("Set as focus task") { model.selectFocusTask(task.id) }
            Divider()
        }
        Button("Edit…") { model.route = .edit(task.id) }
        Button("Add subtask") { model.addingUnder = task.id }
        Button("Duplicate") { model.duplicate(task.id) }
        if task.depth == 0 {
            Menu("Up next") {
                Button("Move to top") { model.moveTask(task.id, by: Int.min) }
                Button("Move up") { model.moveTask(task.id, by: -1) }
                Button("Move down") { model.moveTask(task.id, by: 1) }
                Button("Move to bottom") { model.moveTask(task.id, by: Int.max) }
            }
        }
        Menu("Priority") {
            ForEach([Priority.high, .medium, .low], id: \.self) { p in
                Button(p.rawValue.capitalized) { model.update(task.id, TaskPatch(priority: .some(p))) }
            }
            Button("None") { model.update(task.id, TaskPatch(priority: .some(nil))) }
        }
        Menu("Due date") {
            Button("Today") { setDue(0) }
            Button("Tomorrow") { setDue(1) }
            Button("In a week") { setDue(7) }
            Button("No due date") { model.update(task.id, TaskPatch(due: .some(nil))) }
        }
        if task.depth == 0 || task.group != nil {
            Menu("Move to") {
                ForEach(model.groups.filter { $0 != task.group }, id: \.self) { g in
                    Button(g) { model.update(task.id, TaskPatch(group: .some(g))) }
                }
                if task.group != nil { Button("No group") { model.update(task.id, TaskPatch(group: .some(nil))) } }
            }
        }
        Divider()
        Button("Delete…", role: .destructive) { model.pendingDelete = task.id }
    }

    private func setDue(_ days: Int) {
        let d = Calendar.current.date(byAdding: .day, value: days, to: Date())!
        model.update(task.id, TaskPatch(due: .some(Dates.dayKey(d))))
    }
}

struct AddTaskField: View {
    @EnvironmentObject var model: AppModel
    var parentId: String? = nil
    var group: String? = nil
    var placeholder: String
    var depth: Int = 0
    var compact = false
    var autofocus = false
    @ViewState private var text = ""
    @ViewState private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(focused ? Theme.accent : Theme.tertiary)
                .frame(width: 16)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 12 : 13))
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand {
                    text = ""
                    focused = false
                    if parentId != nil { model.addingUnder = nil }
                    if group != nil { model.addingGroup = nil }
                }
        }
        .padding(.vertical, compact ? 3 : 6)
        .padding(.leading, CGFloat(depth) * 20 + 6)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(focused ? Theme.surface : (hover ? Theme.surface.opacity(0.6) : .clear)))
        .opacity(compact && !focused && !hover && text.isEmpty ? 0.55 : 1)
        .onHover { hover = $0 }
        .onAppear { if parentId != nil || autofocus { focused = true } }
        .onChange(of: model.focusAddField) { _, _ in if parentId == nil && group == nil { focused = true } }
        .onChange(of: focused) { _, f in
            if !f && parentId != nil && text.isEmpty { model.addingUnder = nil }
            if !f && group != nil && text.isEmpty { model.addingGroup = nil }
        }
        .accessibilityLabel(placeholder)
    }

    private func submit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        model.addTask(t, parentId: parentId, group: group)
        text = ""
        focused = true      // keep typing the next one
    }
}
