import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    let onChooseVault: () -> Void
    @ViewState private var s = AppSettings()
    @ViewState private var loaded = false
    @ViewState private var apiKey = ""
    @ViewState private var hasKey = Keychain.read(Keychain.anthropicAccount) != nil
    @ViewState private var saveTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Vault") {
                    Text(model.service?.layout.vault.path ?? "Not set")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack(spacing: 0) {
                        Button("Change…", action: onChooseVault).buttonStyle(QuietButtonStyle(tint: Theme.accent))
                        Button("Open folder") { model.openDataFolder() }.buttonStyle(QuietButtonStyle(tint: Theme.secondary))
                    }
                    .padding(.leading, -12)
                }

                section("Timer") {
                    Stepper(value: $s.defaultFocusMinutes, in: s.minFocusMinutes...s.maxFocusMinutes, step: s.timerStepMinutes) {
                        row("Default focus", "\(s.defaultFocusMinutes) min")
                    }
                    Toggle("Sound when a session ends", isOn: $s.sound)
                    Toggle("Notification when a session ends", isOn: $s.notifications)
                    Toggle("Completing the focus task stops the timer", isOn: $s.completingTaskStopsFocus)
                }

                section("Appearance") {
                    Picker("Theme", selection: $s.theme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Opacity")
                        Slider(value: $s.opacity, in: 0.6...1)
                    }
                }

                section("Assistant") {
                    Toggle("Enable assistant", isOn: $s.aiEnabled)
                    if s.aiEnabled {
                        Picker("Model", selection: $s.aiProvider) {
                            Text("On this Mac").tag("apple")
                            Text("Claude (API key)").tag("anthropic")
                        }
                        .pickerStyle(.segmented)
                        if s.aiProvider == "apple" {
                            Text("Uses Apple Intelligence's built-in model. Private, free, and needs no download. Best for adding and editing tasks; summaries are basic.")
                                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack {
                                SecureField(hasKey ? "Key saved in Keychain" : "Paste API key", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                                Button("Save") {
                                    if Keychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.anthropicAccount) {
                                        hasKey = true
                                        apiKey = ""
                                    }
                                }
                                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                                if hasKey {
                                    Button("Remove") { Keychain.delete(Keychain.anthropicAccount); hasKey = false }
                                }
                            }
                            TextField("Model (default \(AnthropicProvider.defaultModel))", text: $s.aiModel)
                                .textFieldStyle(.roundedBorder)
                            Text("Your request and open tasks are sent to Anthropic when you ask the assistant. The key is stored in the macOS Keychain, never in your vault.")
                                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                        }
                        Toggle("Ask before the assistant deletes tasks", isOn: $s.aiConfirmDestructive)
                    }
                }

                section("Keyboard") {
                    VStack(alignment: .leading, spacing: 3) {
                        shortcut("⌘N", "Add task")
                        shortcut("↑ ↓", "Move through tasks")
                        shortcut("Space", "Check / uncheck task")
                        shortcut("↩ or F", "Make it the focus task")
                        shortcut("E", "Edit task")
                        shortcut("⌘↩", "Start / pause timer")
                        shortcut("⌘⇧F", "Choose focus task")
                        shortcut("⌘K", "Assistant")
                        shortcut("⌘Y", "History")
                        shortcut("⌘M", "Collapse to floating button")
                        shortcut("Esc", "Back / return to your previous app")
                    }
                }

                section("Terminal") {
                    VStack(alignment: .leading, spacing: 3) {
                        shortcut("floatask", "Open the panel")
                        shortcut("floatask quit", "Close the app")
                        shortcut("floatask help", "All commands")
                    }
                }

                HStack {
                    Text("Settings are saved to Settings.md in your vault.")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.tertiary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle(tint: Theme.secondary))
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5))
            .padding(12)
        }
        .scrollIndicators(.never)
        .onAppear {
            if !loaded { s = model.snapshot.settings; loaded = true }
        }
        .onChange(of: s) { _, new in
            guard loaded, new != model.snapshot.settings else { return }
            // Debounced so dragging the opacity slider doesn't rewrite Settings.md on every tick.
            saveTask?.cancel()
            saveTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { model.saveSettings(new) }
            }
        }
    }

    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.label(title)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(Theme.secondary).monospacedDigit()
        }
    }

    private func shortcut(_ keys: String, _ what: String) -> some View {
        HStack {
            Text(keys).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text).frame(width: 96, alignment: .leading)
            Text(what).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
        }
    }
}
