import AppKit
import Carbon
import SwiftUI

final class SettingsWindow {
    private var window: NSWindow?
    private let settings: Settings
    private let permissions: Permissions
    private let hotKeys: HotKeys
    private let gates: GateStore
    private let updates: Updates

    init(settings: Settings, permissions: Permissions, hotKeys: HotKeys, gates: GateStore, updates: Updates) {
        self.settings = settings
        self.permissions = permissions
        self.hotKeys = hotKeys
        self.gates = gates
        self.updates = updates
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Ground Control Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, permissions: permissions, hotKeys: hotKeys, gates: gates, updates: updates))
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
    let updates: Updates

    var body: some View {
        TabView {
            strip.tabItem { Label("Airspace", systemImage: "rectangle.topthird.inset.filled") }
            gatesTab.tabItem { Label("Gates", systemImage: "square.split.2x1") }
            flyBys.tabItem { Label("Fly-bys", systemImage: "airplane") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 600)
        .onChange(of: settings.keepClear) { _, on in requestIfNeeded(on, .accessibility) }
        .onChange(of: settings.flyByPreview) { _, on in requestIfNeeded(on, .screenRecording) }
        .onChange(of: settings.size) { _, size in requestIfNeeded(size == .large, .screenRecording) }
    }

    private var strip: some View {
        Form {
            Section {
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
                        reason: "Large tiles show a small picture of each app's window, which uses Screen Recording. Without it they show the app's icon."
                    )
                }
                Toggle("Hide the airspace until you need it", isOn: $settings.autoHide)
                if settings.autoHide {
                    note("Apps get the whole screen. The airspace comes out at its edge, while ⌃⌥ is held, briefly after a gate shortcut or swipe, and during a fly-by.")
                }
                Toggle("Keep windows out from under the airspace", isOn: $settings.keepClear)
                if settings.keepClear {
                    PermissionNote(
                        permission: .accessibility,
                        granted: permissions.accessibility,
                        reason: "Moving windows uses Accessibility. Without it the airspace hides until the pointer reaches its edge, and clicking an app only brings it forward."
                    )
                }
            }

            Section("Apps in your airspace") {
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
    }

    private var gatesTab: some View {
        Form {
            Section {
                Toggle("Grow the app you're using", isOn: $settings.squish)
                if settings.squish {
                    Stepper("Grows by \(Int(settings.squishAmount * 100))%", value: $settings.squishAmount, in: 0.1...0.6, step: 0.05)
                }
                Stepper(settings.gateGap == 0 ? "No space between apps" : "\(Int(settings.gateGap))pt between apps", value: $settings.gateGap, in: 0...16, step: 2)
                Picker("Switching gates", selection: $settings.switchSpeed) {
                    ForEach(SwitchSpeed.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Open an app's gate when you switch to it", isOn: $settings.autoOpen)
            }
            Section {
                Picker("Swipe to switch gates", selection: $settings.swipeFingers) {
                    Text("Off").tag(0)
                    Text("Three fingers").tag(3)
                    Text("Four fingers").tag(4)
                    Text("Five fingers").tag(5)
                }
                if settings.swipeFingers > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        note(swipeNote)
                        Spacer(minLength: 0)
                        Button("Open Trackpad…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!)
                        }
                        .controlSize(.small)
                    }
                }
            }
            Section {
                note("Gates move and resize windows with Accessibility. Build one with + in the airspace; right-click a gate to edit it, drag it to reorder.")
            }
        }
        .formStyle(.grouped)
    }

    private var flyBys: some View {
        Form {
            Section {
                Toggle("Fly-by when something needs you", isOn: $settings.flyBy)
                if settings.flyBy {
                    Picker("For", selection: $settings.flyByTrigger) {
                        ForEach(FlyByTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("When a terminal finishes", isOn: $settings.terminalFinished)
                    Toggle("Show a live preview of the app's window", isOn: $settings.flyByPreview)
                    Stepper("Stays for \(Int(settings.flyBySeconds)) seconds", value: $settings.flyBySeconds, in: 2...20)
                    if settings.flyByPreview || settings.terminalFinished {
                        PermissionNote(
                            permission: .screenRecording,
                            granted: permissions.screenRecording,
                            reason: "Previews, and noticing a terminal go quiet, use Screen Recording. Without it the app's tile pulses in the airspace instead."
                        )
                    }
                }
            }
            if settings.flyBy {
                Section("Urgent") {
                    TextField("Words and people", text: $settings.urgentWords, prompt: Text("urgent, prod, Jane"))
                    Stepper("Mentions turn urgent at \(settings.urgentMentions)", value: $settings.urgentMentions, in: 2...50)
                    PermissionNote(
                        permission: .accessibility,
                        granted: permissions.accessibility,
                        reason: "Urgent fly-bys always come through, even while holding. Notifications are read with Accessibility and their text stays on this Mac."
                    )
                }
                Section("Holding pattern") {
                    Toggle("Hold while you're focused", isOn: $settings.holdWhileFocused)
                    if settings.holdWhileFocused {
                        Stepper("For at most \(Int(settings.holdMinutes)) min", value: $settings.holdMinutes, in: 1...15)
                    }
                    Toggle("Hold during calls", isOn: $settings.meetingMode)
                    if settings.meetingMode {
                        Picker("Open during calls", selection: $settings.meetingGate) {
                            Text("Nothing").tag("")
                            ForEach(gates.gates) { Text($0.name).tag($0.id.uuidString) }
                        }
                    }
                    note("Focused is two minutes in one app while typing; a call is the microphone or camera on. Held fly-bys come at the next break.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section {
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
            }
            Section {
                note("⌃⌥1 to ⌃⌥9 open gates by their place in the airspace; hold ⌃⌥ to see every key where it applies. Click a shortcut and press new keys with ⌃, ⌥ or ⌘; Delete turns it off, Esc cancels.")
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        Form {
            Section {
                LabeledContent("Version", value: updates.current)
                Toggle("Check for updates automatically", isOn: Binding(get: { updates.automatic }, set: { updates.automatic = $0 }))
                Button("Check for Updates…") { updates.check(asked: true) }
            }
            Section {
                Link("Ground Control on GitHub", destination: URL(string: "https://github.com/\(Updates.repo)")!)
            }
        }
        .formStyle(.grouped)
    }

    /// macOS uses three- and four-finger side swipes itself, and Ground Control can't stop it, so
    /// those have to be turned off or moved in Trackpad settings first.
    private var swipeNote: String {
        let swipe = "Swipe left for the next gate, right for the previous."
        switch settings.swipeFingers {
        case 3, 4:
            return swipe + " On a single desktop this usually works as it is. With more desktops or full-screen apps, macOS would switch those too: in Trackpad → More Gestures, give \"Swipe between full-screen applications\" other fingers or turn it off\(settings.swipeFingers == 3 ? ", and keep \"Swipe between pages\" on two fingers" : "")."
        default:
            return swipe + " macOS doesn't use five-finger swipes, so nothing needs changing."
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
