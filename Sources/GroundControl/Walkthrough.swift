import AppKit
import SwiftUI

/// The first-run tour: what Ground Control is, the two permissions and why, building a first gate,
/// and the shortcuts. Shown once, and again from the menu.
final class Walkthrough {
    private var window: NSWindow?
    private let permissions: Permissions
    private let newGate: () -> Void
    private let seenKey = "walkthroughSeen"

    init(permissions: Permissions, newGate: @escaping () -> Void) {
        self.permissions = permissions
        self.newGate = newGate
    }

    func showIfFirstRun() {
        guard !UserDefaults.standard.bool(forKey: seenKey) else { return }
        show()
    }

    func show() {
        UserDefaults.standard.set(true, forKey: seenKey)
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Welcome to Ground Control"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WalkthroughView(permissions: permissions) { [weak self, weak window] build in
                window?.close()
                if build { self?.newGate() }
            })
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct WalkthroughView: View {
    @ObservedObject var permissions: Permissions
    /// `true` to build a first gate on the way out.
    let done: (Bool) -> Void
    @State private var page = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                switch page {
                case 0: welcome
                case 1: access
                case 2: gates
                default: keys
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<4) { index in
                        Circle().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                if page < 3 {
                    Button("Skip") { done(false) }
                    Button("Next") { page += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Later") { done(false) }
                    Button("Build a Gate") { done(true) }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 420)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            Text("Work on one screen without swiping between desktops.").font(.title2.bold())
            point("airplane", "Airspace", "The apps you're not looking at circle along one edge, with their badges, until they're needed.")
            point("square.split.2x1", "Gates", "Apps you use together, laid out side by side. One click or swipe brings the whole arrangement back.")
            point("bell.badge", "Fly-bys", "What needs you floats past for a few seconds without taking your focus, and waits while you're busy.")
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Two permissions, both optional").font(.title2.bold())
            Text("Ground Control works without either; each one adds to it. You can change them any time in Settings.")
                .foregroundStyle(.secondary)
            PermissionNote(
                permission: .accessibility,
                granted: permissions.accessibility,
                reason: "Accessibility moves and resizes windows for gates, and reads notification banners to tell what's urgent. Their text stays on your Mac."
            )
            PermissionNote(
                permission: .screenRecording,
                granted: permissions.screenRecording,
                reason: "Screen Recording shows live previews of windows in the airspace and fly-bys, and notices when a terminal finishes."
            )
        }
    }

    private var gates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build your first gate").font(.title2.bold())
            point("plus.square.dashed", "Click + in the airspace", "Other apps step aside, and an overlay covers the screen.")
            point("hand.draw", "Drag apps in", "Drop an app on an edge of another to split that way. Drag the borders to resize; the real windows follow.")
            point("checkmark.circle", "Save", "Clicking the gate brings the arrangement back. Right-click to edit it or move it to the hangar.")
        }
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hold ⌃⌥ to see the keys").font(.title2.bold())
            Text("Hold Control and Option anywhere, and each shortcut shows where it applies.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                key("⌃⌥1 – 9", "open a gate by its place")
                key("⌃⌥H  ⌃⌥L", "the gate to the left or right")
                key("⌃⌥N", "the next app in the gate")
                key("⌃⌥M", "answer a fly-by")
                key("⌃⌥0", "show the desktop")
            }
            Text("Change any of them in Settings → Shortcuts. This tour is in the menu bar menu if you want it again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 26).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func key(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys).font(.system(.body, design: .rounded).bold())
            Text(action).foregroundStyle(.secondary)
        }
    }
}
