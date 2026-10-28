import AppKit
import Carbon
import SwiftUI

/// While ⌃⌥ is held, each shortcut's key shows where it applies, so they're easy to learn. Reads
/// only which modifier keys are down, which needs no permission.
final class KeyHints: ObservableObject {
    static let shared = KeyHints()

    @Published private(set) var showing = false
    private var heldSince: Date?

    /// Called often. Waits a moment so a quick shortcut doesn't flash the hints.
    func poll() {
        let held = NSEvent.modifierFlags.intersection([.control, .option, .command]) == [.control, .option]
        guard held else {
            heldSince = nil
            if showing { showing = false }
            return
        }
        let since = heldSince ?? Date()
        heldSince = since
        if !showing, Date().timeIntervalSince(since) > 0.35 { showing = true }
    }
}

extension Settings {
    /// What to press for `action` with ⌃⌥ already held: the key, with ⇧ if it needs it, or the
    /// whole shortcut when it's set to something other than ⌃⌥.
    func hint(_ action: ShortcutAction) -> String? {
        let shortcut = shortcut(for: action)
        guard !shortcut.isNone else { return nil }
        let base = UInt32(controlKey | optionKey)
        if shortcut.modifiers == base { return shortcut.key }
        if shortcut.modifiers == base | UInt32(shiftKey) { return "⇧" + shortcut.key }
        return shortcut.display
    }
}

/// A key as it's printed on a keyboard.
struct KeyCap: View {
    let text: String
    var size: CGFloat = 10

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, size * 0.4)
            .padding(.vertical, size * 0.1)
            .background(RoundedRectangle(cornerRadius: size * 0.35).fill(Color.primary.opacity(0.85)))
            .fixedSize()
    }
}

/// Large key caps floating in the middle of windows: which key brings each of the open gate's
/// other apps forward.
final class WindowHints {
    private var panels: [NSPanel] = []

    /// `hints` are in AX coordinates.
    func show(_ hints: [(frame: CGRect, text: String)]) {
        while panels.count > hints.count {
            panels.removeLast().orderOut(nil)
        }
        while panels.count < hints.count {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
            panels.append(panel)
        }
        for (panel, hint) in zip(panels, hints) {
            panel.contentView = NSHostingView(rootView: KeyCap(text: hint.text, size: 28).shadow(radius: 6))
            let size = panel.contentView?.fittingSize ?? CGSize(width: 60, height: 44)
            let center = WindowMover.appKitFrame(hint.frame)
            panel.setFrame(CGRect(x: center.midX - size.width / 2, y: center.midY - size.height / 2, width: size.width, height: size.height), display: true)
            panel.orderFrontRegardless()
        }
    }
}
