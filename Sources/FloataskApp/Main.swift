import AppKit
import Combine
import SwiftUI

@main
enum FloataskMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)     // no Dock icon; lives as a floating panel
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var panel: FloatingPanel!
    private var pill: FloatingPanel!
    private var keyMonitor: Any?
    private var saveWork: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    static let commandNotification = AppIdentity.commandNotification

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { setUp() }
    }

    @MainActor
    private func setUp() {
        installMenu()
        model = AppModel()

        // Main panel
        let config = LocalConfig.load()
        panel = FloatingPanel(contentRect: frame(config.panelFrame, default: defaultPanelFrame()), resizable: true)
        panel.minSize = NSSize(width: 290, height: 380)
        panel.maxSize = NSSize(width: 560, height: 1100)
        panel.setAccessibilityTitle("Floatask")
        let root = PanelView(
            onMinimize: { [weak self] in MainActor.assumeIsolated { self?.minimize() } },
            onClose: { NSApp.terminate(nil) },
            onChooseVault: { [weak self] in MainActor.assumeIsolated { self?.chooseVault() } }
        ).environmentObject(model)
        panel.setContent(root)
        panel.onFrameChange = { [weak self] in self?.scheduleSave() }

        // Minimized floating button
        pill = FloatingPanel(contentRect: frame(config.pillFrame, default: defaultPillFrame(), fixedSize: PillView.size), resizable: false)
        pill.setAccessibilityTitle("Floatask (collapsed)")
        let pillHost = PillHostingView(rootView: AnyView(PillView().environmentObject(model)))
        pillHost.onClick = { [weak self] in MainActor.assumeIsolated { self?.restore() } }
        pill.setHostingView(pillHost, cornerRadius: PillView.size.height / 2)
        pill.onFrameChange = { [weak self] in self?.scheduleSave() }

        model.onAppearanceChange = { [weak self] in MainActor.assumeIsolated { self?.applyAppearance() } }
        applyAppearance()

        if config.minimized && !model.needsVault { minimize(animated: false) } else { restore(animated: false) }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleCommand(_:)), name: AppDelegate.commandNotification, object: nil,
            suspensionBehavior: .deliverImmediately)
        installKeyMonitor()
    }

    // MARK: Show / hide

    @MainActor
    func minimize(animated: Bool = true) {
        pill.setFrameOrigin(onScreen(pill.frame).origin)
        pill.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.panel.orderOut(nil)
                self?.applyAppearance()
            })
        } else {
            panel.orderOut(nil)
        }
        setMinimized(true)
    }

    @MainActor
    func restore(animated: Bool = true) {
        panel.setFrame(onScreen(panel.frame), display: false)
        pill.orderOut(nil)
        panel.alphaValue = animated ? 0 : CGFloat(model.snapshot.settings.opacity)
        panel.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                panel.animator().alphaValue = CGFloat(model.snapshot.settings.opacity)
            }
        }
        setMinimized(false)
    }

    private func setMinimized(_ value: Bool) {
        var c = LocalConfig.load()
        c.minimized = value
        try? c.save()
    }

    @MainActor
    private func applyAppearance() {
        let appearance: NSAppearance?
        switch model.snapshot.settings.theme {
        case "light": appearance = NSAppearance(named: .aqua)
        case "dark": appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil
        }
        panel.appearance = appearance
        pill.appearance = appearance
        if panel.isVisible { panel.alphaValue = CGFloat(model.snapshot.settings.opacity) }
        pill.alphaValue = 1
    }

    @MainActor
    private func chooseVault() {
        NSApp.activate()
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.prompt = "Use This Vault"
        open.message = "Choose your Obsidian vault folder. Floatask will keep its files in a “Task Manager” folder inside it."
        if open.runModal() == .OK, let url = open.url {
            model.chooseVault(url)
        }
        panel.orderFrontRegardless()
    }

    @objc private func handleCommand(_ note: Notification) {
        guard let command = note.object as? String else { return }
        MainActor.assumeIsolated {
            switch command {
            case "show": restore()
            case "hide": minimize()
            case "quit": NSApp.terminate(nil)
            case "reload": model.connect()
            case let c where c.hasPrefix("route:"):
                // Development aid: `route:history` etc. switches screens so snapshots can be reviewed.
                switch c.dropFirst(6) {
                case "history": model.route = .history
                case "assistant": model.route = .assistant
                case "settings": model.route = .settings
                case "picker": model.route = .picker
                default: model.route = .tasks
                }
            case let c where c.hasPrefix("view:"):
                if let v = ListView(rawValue: String(c.dropFirst(5))) { model.route = .tasks; model.setListView(v) }
            case "snapshot": writeSnapshots()
            default: break
            }
        }
    }

    /// Renders the panel and pill into PNGs under Application Support/Floatask/snapshots (no screen-recording
    /// permission needed, since the app draws its own views).
    @MainActor
    private func writeSnapshots() {
        let dir = LocalConfig.directory.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, window) in [("panel", panel!), ("pill", pill!)] {
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { restore() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { saveFrames() }

    // MARK: Frames

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrames() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveFrames() {
        guard panel != nil else { return }
        var c = LocalConfig.load()
        let p = panel.frame, q = pill.frame
        c.panelFrame = [p.origin.x, p.origin.y, p.width, p.height]
        c.pillFrame = [q.origin.x, q.origin.y, q.width, q.height]
        try? c.save()
    }

    private func frame(_ saved: [Double]?, default def: NSRect, fixedSize: NSSize? = nil) -> NSRect {
        guard let s = saved, s.count == 4 else { return def }
        var r = NSRect(x: s[0], y: s[1], width: s[2], height: s[3])
        if let fixedSize { r.size = fixedSize }
        return onScreen(r)
    }

    /// Keeps a window fully visible on some screen (e.g. after a display was unplugged).
    private func onScreen(_ r: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let screen = screens.first { $0.visibleFrame.intersects(r) } ?? NSScreen.main ?? screens.first
        guard let vf = screen?.visibleFrame else { return r }
        var out = r
        out.size.width = min(out.width, vf.width)
        out.size.height = min(out.height, vf.height)
        out.origin.x = min(max(out.minX, vf.minX), vf.maxX - out.width)
        out.origin.y = min(max(out.minY, vf.minY), vf.maxY - out.height)
        return out
    }

    private func defaultPanelFrame() -> NSRect {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 320, height: min(560, vf.height - 48))
        return NSRect(x: vf.maxX - size.width - 24, y: vf.maxY - size.height - 24, width: size.width, height: size.height)
    }

    private func defaultPillFrame() -> NSRect {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: vf.maxX - PillView.size.width - 24, y: vf.maxY - PillView.size.height - 24,
                      width: PillView.size.width, height: PillView.size.height)
    }

    // MARK: Menu + keyboard

    /// An accessory app has no visible menu bar, but a main menu is still needed for ⌘C/⌘V/⌘Z in text fields.
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Floatask", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @MainActor
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) ? nil : event }
        }
    }

    /// App shortcuts. Returns true when the event was consumed.
    @MainActor
    private func handleKey(_ e: NSEvent) -> Bool {
        guard e.window === panel else { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let editingText = panel.firstResponder is NSTextView

        if mods == .command {
            switch key {
            case "\r": model.togglePause(); return true                 // ⌘↩ start / pause
            case "k": model.route = .assistant; model.focusAssistantField += 1; return true
            case "y": model.route = model.route == .history ? .tasks : .history; return true
            case "n": model.route = .tasks; model.addingUnder = nil; model.focusAddField += 1; return true
            case ",": model.route = model.route == .settings ? .tasks : .settings; return true
            case "m", "w": minimize(); return true
            case "1", "2", "3":
                model.route = .tasks
                model.setListView(ListView.allCases[Int(key)! - 1])
                return true
            case "c", "v", "x", "a", "z":
                let sel: Selector = ["c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
                                     "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
                                     "z": Selector(("undo:"))][key]!
                return NSApp.sendAction(sel, to: nil, from: nil)
            default: break
            }
        }
        if mods == [.command, .shift] {
            if key == "f" { model.route = .picker; return true }
            if key == "z" { return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
        }
        if e.keyCode == 53 {   // Esc
            if model.pendingSwitch != nil { model.pendingSwitch = nil; return true }
            if model.pendingDelete != nil { model.pendingDelete = nil; return true }
            if model.route != .tasks && !editingText { model.route = .tasks; return true }
            if model.route == .tasks && !editingText && model.highlightedId != nil { model.highlightedId = nil; return true }
            if model.route == .tasks && !editingText && model.addingUnder == nil { panel.resignKeyAndReturn(); return true }
            return false
        }
        // ⌥↑ / ⌥↓ moves the highlighted task within "Up next".
        if mods == .option, model.route == .tasks, model.listView == .upNext, !editingText, e.keyCode == 125 || e.keyCode == 126,
           let id = model.highlightedId, model.snapshot.task(id)?.depth == 0 {
            model.moveTask(id, by: e.keyCode == 125 ? 1 : -1)
            return true
        }
        // List navigation when not typing.
        guard model.route == .tasks, !editingText, mods.isDisjoint(with: [.command, .option, .control]) else { return false }
        let list = model.displayedTasks
        switch e.keyCode {
        case 125, 126:   // ↓ ↑
            guard !list.isEmpty else { return false }
            let idx = list.firstIndex { $0.id == model.highlightedId }
            let next = e.keyCode == 125 ? (idx.map { min($0 + 1, list.count - 1) } ?? 0) : (idx.map { max($0 - 1, 0) } ?? list.count - 1)
            model.highlightedId = list[next].id
            return true
        case 49:         // Space
            guard let id = model.highlightedId else { return false }
            model.toggle(id); return true
        case 36:         // Return → make it the focus task
            guard let id = model.highlightedId else { return false }
            model.selectFocusTask(id); return true
        default:
            if key == "e", let id = model.highlightedId { model.route = .edit(id); return true }
            if key == "f", let id = model.highlightedId { model.selectFocusTask(id); return true }
            return false
        }
    }
}

// MARK: - Floating panel

final class FloatingPanel: NSPanel {
    var onFrameChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(contentRect: NSRect, resizable: Bool) {
        var mask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        super.init(contentRect: contentRect, styleMask: mask, backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in
                self?.invalidateShadow()
                self?.onFrameChange?()
            })
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        setHostingView(host)
    }

    func setHostingView(_ host: NSView, cornerRadius: CGFloat = Theme.radius) {
        host.wantsLayer = true
        host.layer?.cornerRadius = cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        contentView = host
        invalidateShadow()
    }

    /// Hands keyboard focus back to whatever app the user was working in.
    func resignKeyAndReturn() {
        makeFirstResponder(nil)
        resignKey()
    }
}

/// NSHostingView for the collapsed button: click restores, drag moves (anywhere on the pill).
final class PillHostingView: NSHostingView<AnyView> {
    var onClick: (() -> Void)?
    private var startMouse: NSPoint = .zero
    private var startOrigin: NSPoint = .zero
    private var dragging = false

    required init(rootView: AnyView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startOrigin = window?.frame.origin ?? .zero
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - startMouse.x, dy = p.y - startMouse.y
        if !dragging && hypot(dx, dy) < 3 { return }
        dragging = true
        window?.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { onClick?() }
        dragging = false
    }
}

/// Place behind a header to make it drag the window; controls on top keep working.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Bottom-right grip that resizes the borderless panel.
struct ResizeGrip: NSViewRepresentable {
    final class GripView: NSView {
        private var startMouse: NSPoint = .zero
        private var startFrame: NSRect = .zero
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startFrame = window?.frame ?? .zero
        }
        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            let p = NSEvent.mouseLocation
            var width = startFrame.width + (p.x - startMouse.x)
            var height = startFrame.height - (p.y - startMouse.y)
            width = min(max(width, w.minSize.width), w.maxSize.width)
            height = min(max(height, w.minSize.height), w.maxSize.height)
            w.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height), display: true)
        }
    }
    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
