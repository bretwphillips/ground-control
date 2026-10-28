import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags.
    var modifiers: UInt32
    /// The key as shown, like "L" or "Tab".
    var key: String

    /// Turned off by the user.
    static let none = Shortcut(keyCode: .max, modifiers: 0, key: "")

    var isNone: Bool { keyCode == .max }

    var display: String {
        guard !isNone else { return "Off" }
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + key
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// A key press with ⌃, ⌥ or ⌘ held, so plain typing can't set one off.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: Self.name(of: event))
    }

    private static func name(of event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Tab: "Tab"
        case kVK_Space: "Space"
        case kVK_Return: "Return"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

enum ShortcutAction: String, CaseIterable {
    case gateLeft, gateRight, back, appNext, appPrevious, answer, desktop

    var title: String {
        switch self {
        case .gateLeft: "Gate to the left"
        case .gateRight: "Gate to the right"
        case .back: "Back to the last gate"
        case .appNext: "Next app in the gate"
        case .appPrevious: "Previous app in the gate"
        case .answer: "Answer the fly-by"
        case .desktop: "Show the desktop"
        }
    }

    /// ⌃⌥ held by the left hand, a right-hand key, clear of what Magnet takes (D F G E T U I J K,
    /// the arrows, Return).
    var standard: Shortcut {
        let base = UInt32(controlKey | optionKey)
        return switch self {
        case .gateLeft: Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: base, key: "H")
        case .gateRight: Shortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: base, key: "L")
        case .back: Shortcut(keyCode: UInt32(kVK_Tab), modifiers: base, key: "Tab")
        case .appNext: Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: base, key: "N")
        case .appPrevious: Shortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: base | UInt32(shiftKey), key: "N")
        case .answer: Shortcut(keyCode: UInt32(kVK_ANSI_M), modifiers: base, key: "M")
        case .desktop: Shortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: base, key: "0")
        }
    }
}
