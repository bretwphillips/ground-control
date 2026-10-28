import AppKit
import SwiftUI

final class SettingsWindow {
    private var window: NSWindow?
    private let settings: Settings
    private let permissions: Permissions

    init(settings: Settings, permissions: Permissions) {
        self.settings = settings
        self.permissions = permissions
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
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, permissions: permissions))
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
                Text("⌃⌥1 to ⌃⌥9 open gates, ⌃⌥[ and ⌃⌥] step through them, and ⌃⌥Tab flips back to the one before. ⌃⌥` and ⌃⌥⇧` switch apps within the gate. Moving and resizing windows uses Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fly-by") {
                Toggle("Fly-by when an app's badge shows a number", isOn: $settings.flyBy)
                if settings.flyBy {
                    Stepper("Stays for \(Int(settings.flyBySeconds)) seconds", value: $settings.flyBySeconds, in: 2...20)
                    Text("⌃⌥\\ answers it without clicking: it opens the app's gate, or the app on its own. It still works for a minute after the fly-by leaves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Show a live preview of the app's window", isOn: $settings.flyByPreview)
                    if settings.flyByPreview {
                        PermissionNote(
                            permission: .screenRecording,
                            granted: permissions.screenRecording,
                            reason: "Uses Screen Recording to show the app's window in a floating preview that never takes focus. Without it, the app's tile pulses in the strip instead."
                        )
                    }
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
