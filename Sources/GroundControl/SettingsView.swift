import AppKit
import Carbon
import SwiftUI

final class SettingsWindow {
    private var window: NSWindow?
    private let settings: Settings
    private let permissions: Permissions
    private let hotKeys: HotKeys
    private let gates: GateStore

    init(settings: Settings, permissions: Permissions, hotKeys: HotKeys, gates: GateStore) {
        self.settings = settings
        self.permissions = permissions
        self.hotKeys = hotKeys
        self.gates = gates
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Ground Control Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, permissions: permissions, hotKeys: hotKeys, gates: gates))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var permissions: Permissions
    @ObservedObject var hotKeys: HotKeys
    @ObservedObject var gates: GateStore

    var body: some View {
        Form {
            Section("Strip") {
                Picker("Edge", selection: $settings.edge) {
                    ForEach(StripEdge.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Size", selection: $settings.size) {
                    ForEach(StripSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if settings.size == .large {
                    PermissionNote(
                        permission: .screenRecording,
                        granted: permissions.screenRecording,
                        reason: "Large tiles use Screen Recording to show a small picture of each app's window. Without it, they show the app's icon."
                    )
                }
            }

            Section("Windows") {
                Toggle("Keep windows out from under the strip", isOn: $settings.keepClear)
                if settings.keepClear {
                    PermissionNote(
                        permission: .accessibility,
                        granted: permissions.accessibility,
                        reason: "Uses Accessibility to move and resize other apps' windows. Without it, the strip hides until you push the pointer to its edge, and clicking an app only brings it forward."
                    )
                }
            }

            Section("Gates") {
                Toggle("Grow the app you're using", isOn: $settings.squish)
                if settings.squish {
                    Stepper("Grows by \(Int(settings.squishAmount * 100))%", value: $settings.squishAmount, in: 0.1...0.6, step: 0.05)
                }
                Toggle("Open an app's gate when you switch to it", isOn: $settings.autoOpen)
                Picker("Swipe to switch gates", selection: $settings.swipeFingers) {
                    Text("Off").tag(0)
                    Text("Four fingers").tag(4)
                    Text("Five fingers").tag(5)
                }
                if settings.swipeFingers > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Swipe left for the next gate and right for the previous, wrapping around. If the swipe also switches desktops, set \"Swipe between full-screen applications\" to other fingers in Trackpad settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Open Trackpad…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                }
                Text("Moving and resizing windows uses Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HStack(spacing: 6) {
                            if hotKeys.taken.contains(action) {
                                Text("in use by another app").font(.caption).foregroundStyle(.orange)
                            }
                            ShortcutRecorder(shortcut: settings.shortcut(for: action), hotKeys: hotKeys) { recorded in
                                settings.shortcuts[action.rawValue] = recorded
                            }
                            if settings.shortcuts[action.rawValue] != nil {
                                Button("Reset") { settings.shortcuts[action.rawValue] = nil }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                Text("⌃⌥1 to ⌃⌥9 open gates by their place in the strip. Click a shortcut and press new keys (with ⌃, ⌥ or ⌘); Delete turns it off, Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fly-by") {
                Toggle("Fly-by when something needs you", isOn: $settings.flyBy)
                if settings.flyBy {
                    Picker("Fly-by for", selection: $settings.flyByTrigger) {
                        ForEach(FlyByTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Urgent words and people", text: $settings.urgentWords, prompt: Text("urgent, prod, Jane"))
                    PermissionNote(
                        permission: .accessibility,
                        granted: permissions.accessibility,
                        reason: "Notifications that mention any of these (comma separated) are urgent: they always fly by, even while you're focused or in a call. Reading notifications uses Accessibility; their text stays on this Mac."
                    )
                    Stepper("Mentions turn urgent at \(settings.urgentMentions)", value: $settings.urgentMentions, in: 2...50)
                    Toggle("When a terminal finishes", isOn: $settings.terminalFinished)
                    if settings.terminalFinished {
                        PermissionNote(
                            permission: .screenRecording,
                            granted: permissions.screenRecording,
                            reason: "A terminal that was busy for 20 seconds and then goes still flies by, like Claude finishing a task. It's noticed from the window previews, which use Screen Recording."
                        )
                    }
                    Toggle("Show a live preview of the app's window", isOn: $settings.flyByPreview)
                    if settings.flyByPreview {
                        PermissionNote(
                            permission: .screenRecording,
                            granted: permissions.screenRecording,
                            reason: "Uses Screen Recording to show the app's window in a floating preview that never takes focus. Without it, the app's tile pulses in the strip instead."
                        )
                    }
                    Stepper("Stays for \(Int(settings.flyBySeconds)) seconds", value: $settings.flyBySeconds, in: 2...20)
                    Text("\(settings.shortcut(for: .answer).display) answers it without clicking: it opens the app's gate, or the app on its own. It still works for a minute after the fly-by leaves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Holding pattern") {
                Toggle("Hold fly-bys while you're focused", isOn: $settings.holdWhileFocused)
                if settings.holdWhileFocused {
                    Stepper("Hold for at most \(Int(settings.holdMinutes)) min", value: $settings.holdMinutes, in: 1...15)
                    Text("Focused means you've stayed in one app for two minutes and are typing. Held fly-bys come through when you switch apps, pause, or the time's up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Hold fly-bys during calls", isOn: $settings.meetingMode)
                if settings.meetingMode {
                    Picker("Open during calls", selection: $settings.meetingGate) {
                        Text("Nothing").tag("")
                        ForEach(gates.gates) { Text($0.name).tag($0.id.uuidString) }
                    }
                    Text("A call is your microphone or camera being on. When it ends, the gate from before comes back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Apps in Strip") {
                ForEach(runningApps(), id: \.processIdentifier) { app in
                    if let id = app.bundleIdentifier {
                        Toggle(isOn: shown(id)) {
                            Label {
                                Text(app.localizedName ?? id)
                            } icon: {
                                Image(nsImage: app.icon ?? NSImage()).resizable().frame(width: 16, height: 16)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 620)
        .onChange(of: settings.keepClear) { _, on in requestIfNeeded(on, .accessibility) }
        .onChange(of: settings.flyByPreview) { _, on in requestIfNeeded(on, .screenRecording) }
        .onChange(of: settings.size) { _, size in requestIfNeeded(size == .large, .screenRecording) }
    }

    private func requestIfNeeded(_ on: Bool, _ permission: Permission) {
        if on, !permission.isGranted { permission.request() }
    }

    private func runningApps() -> [NSRunningApplication] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != own }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !settings.hiddenApps.contains(id) },
            set: { show in
                if show { settings.hiddenApps.remove(id) } else { settings.hiddenApps.insert(id) }
            }
        )
    }
}

private struct PermissionNote: View {
    let permission: Permission
    let granted: Bool
    let reason: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Allow…") { permission.request() }
                    .controlSize(.small)
            }
        }
    }
}

/// Click, then press the new keys.
private struct ShortcutRecorder: View {
    let shortcut: Shortcut
    let hotKeys: HotKeys
    let set: (Shortcut) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : shortcut.display) {
            recording ? stop() : start()
        }
        .controlSize(.small)
        .frame(minWidth: 90)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        hotKeys.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                set(.none)
                stop()
            default:
                guard let recorded = Shortcut(event: event) else { return nil }
                set(recorded)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        hotKeys.paused = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
