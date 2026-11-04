import SwiftUI

struct PanelView: View {
    @EnvironmentObject var model: AppModel
    let onMinimize: () -> Void
    let onClose: () -> Void
    let onChooseVault: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = model.banner { BannerView(banner: banner) }
            Group {
                if model.needsVault {
                    WelcomeView(onChooseVault: onChooseVault)
                } else {
                    switch model.route {
                    case .tasks: TasksScreen()
                    case .history: HistoryView()
                    case .assistant: AssistantView()
                    case .settings: SettingsView(onChooseVault: onChooseVault)
                    case .edit(let id): TaskEditView(taskId: id)
                    case .picker: TaskPickerView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !model.needsVault { footer }
        }
        .background(Theme.background)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .frame(width: 14, height: 14)
                .overlay(Image(systemName: "line.diagonal").font(.system(size: 8)).foregroundStyle(Theme.tertiary).rotationEffect(.degrees(90)).allowsHitTesting(false))
                .padding(3)
                .help("Drag to resize")
        }
        .overlay { if let id = model.pendingSwitch { SwitchConfirmView(targetId: id) } }
        .overlay { if let id = model.pendingDelete { DeleteConfirmView(taskId: id) } }
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .font(.system(size: 13))
        .animation(.easeOut(duration: 0.15), value: model.route)
    }

    private var header: some View {
        HStack(spacing: 6) {
            if model.route != .tasks && !model.needsVault {
                IconButton(symbol: "chevron.left", help: "Back (Esc)") { model.route = .tasks }
            } else {
                Circle()
                    .fill(model.active?.status == .running ? Theme.focus : Theme.accent)
                    .frame(width: 8, height: 8)
                    .padding(.leading, 6)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            IconButton(symbol: "minus", help: "Collapse to floating button (⌘M)", action: onMinimize)
            IconButton(symbol: "xmark", help: "Quit Taskflow", action: onClose)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(WindowDragArea())
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch model.route {
        case .tasks: return "Taskflow"
        case .history: return "History"
        case .assistant: return "Assistant"
        case .settings: return "Settings"
        case .edit: return "Edit task"
        case .picker: return "Choose focus task"
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("History", symbol: "clock", route: .history, shortcut: "⌘Y")
            footerButton("Assistant", symbol: "sparkles", route: .assistant, shortcut: "⌘K")
            Spacer()
            IconButton(symbol: "ellipsis", help: "Settings (⌘,)") {
                model.route = model.route == .settings ? .tasks : .settings
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func footerButton(_ label: String, symbol: String, route: Route, shortcut: String) -> some View {
        let selected = model.route == route
        return Button {
            model.route = selected ? .tasks : route
            if route == .assistant { model.focusAssistantField += 1 }
        } label: {
            Label(label, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(QuietButtonStyle(tint: selected ? Theme.text : Theme.secondary))
        .help("\(label) (\(shortcut))")
    }
}

struct BannerView: View {
    @EnvironmentObject var model: AppModel
    let banner: Banner

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.message).font(.system(size: 12, weight: .semibold))
                if let d = banner.detail { Text(d).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(3) }
                HStack(spacing: 4) {
                    if banner.retry {
                        Button("Retry") { model.banner = nil; model.reloadFromDisk() }.buttonStyle(QuietButtonStyle())
                    }
                    Button("Open Folder") { model.openDataFolder() }.buttonStyle(QuietButtonStyle())
                }
                .padding(.leading, -12)
            }
            Spacer()
            IconButton(symbol: "xmark", help: "Dismiss", size: 10) { model.banner = nil }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.danger.opacity(0.35)))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct WelcomeView: View {
    let onChooseVault: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checklist").font(.system(size: 30)).foregroundStyle(Theme.accent)
            Text("Choose your Obsidian vault").font(.system(size: 15, weight: .semibold))
            Text("Tasks and focus history are saved as Markdown in a “Task Manager” folder inside it.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Choose Vault…", action: onChooseVault)
                .buttonStyle(QuietButtonStyle(prominent: true, tint: Theme.accent))
            Text("or in Terminal: taskflow config \"/path/to/vault\"")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// "Current session: X — Change task?" (spec §9)
struct SwitchConfirmView: View {
    @EnvironmentObject var model: AppModel
    let targetId: String

    var body: some View {
        ConfirmCard(
            title: "Switch focus task?",
            message: "Current session: “\(model.active?.taskTitle ?? "")”. Its time so far will be saved, and the timer continues on “\(model.snapshot.task(targetId)?.title ?? "no task")”.",
            confirmLabel: "Switch task",
            destructive: false,
            onCancel: { model.pendingSwitch = nil },
            onConfirm: { model.confirmSwitch() })
    }
}

struct DeleteConfirmView: View {
    @EnvironmentObject var model: AppModel
    let taskId: String

    var body: some View {
        let t = model.snapshot.task(taskId)
        let kids = model.snapshot.tasks.filter { $0.parentId == taskId }.count
        ConfirmCard(
            title: "Delete task?",
            message: "“\(t?.title ?? "")”\(kids > 0 ? " and its \(kids) subtask\(kids == 1 ? "" : "s")" : "") will be removed from Tasks.md. Focus history is kept.",
            confirmLabel: "Delete",
            destructive: true,
            onCancel: { model.pendingDelete = nil },
            onConfirm: { model.delete(taskId) })
    }
}

struct ConfirmCard: View {
    let title: String
    let message: String
    let confirmLabel: String
    let destructive: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Theme.background.opacity(0.75).onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel).buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                    Button(confirmLabel, action: onConfirm)
                        .buttonStyle(QuietButtonStyle(prominent: true, tint: destructive ? Theme.danger : Theme.accent))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface).shadow(color: .black.opacity(0.12), radius: 12, y: 4))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
            .padding(18)
        }
        .transition(.opacity)
    }
}
