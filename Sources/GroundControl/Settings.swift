import AppKit

enum StripEdge: String, CaseIterable {
    case top, bottom, left, right

    var title: String { rawValue.capitalized }
    var isHorizontal: Bool { self == .top || self == .bottom }

    var rectEdge: CGRectEdge {
        switch self {
        case .top: .maxYEdge
        case .bottom: .minYEdge
        case .left: .minXEdge
        case .right: .maxXEdge
        }
    }
}

enum FlyByTrigger: String, CaseIterable {
    case everything, mentions, urgent

    var title: String {
        switch self {
        case .everything: "Every notification"
        case .mentions: "Mentions, DMs and urgent"
        case .urgent: "Only urgent"
        }
    }
}

enum StripSize: String, CaseIterable {
    case icons, names, large

    var title: String {
        switch self {
        case .icons: "Icons"
        case .names: "Icons and names"
        case .large: "Large"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var edge: StripEdge {
        didSet { defaults.set(edge.rawValue, forKey: "stripEdge") }
    }
    @Published var size: StripSize {
        didSet { defaults.set(size.rawValue, forKey: "stripSize") }
    }
    /// Bundle ids the user has taken off the strip.
    @Published var hiddenApps: Set<String> {
        didSet { defaults.set(Array(hiddenApps), forKey: "hiddenApps") }
    }
    @Published var keepClear: Bool {
        didSet { defaults.set(keepClear, forKey: "keepClear") }
    }
    @Published var flyBy: Bool {
        didSet { defaults.set(flyBy, forKey: "flyBy") }
    }
    @Published var flyByPreview: Bool {
        didSet { defaults.set(flyByPreview, forKey: "flyByPreview") }
    }
    @Published var flyBySeconds: Double {
        didSet { defaults.set(flyBySeconds, forKey: "flyBySeconds") }
    }
    @Published var flyByTrigger: FlyByTrigger {
        didSet { defaults.set(flyByTrigger.rawValue, forKey: "flyByTrigger") }
    }
    /// Comma-separated words and names that make a notification urgent.
    @Published var urgentWords: String {
        didSet { defaults.set(urgentWords, forKey: "urgentWords") }
    }
    /// Unanswered mentions at or above this many turn urgent.
    @Published var urgentMentions: Int {
        didSet { defaults.set(urgentMentions, forKey: "urgentMentions") }
    }
    @Published var terminalFinished: Bool {
        didSet { defaults.set(terminalFinished, forKey: "terminalFinished") }
    }
    @Published var holdWhileFocused: Bool {
        didSet { defaults.set(holdWhileFocused, forKey: "holdWhileFocused") }
    }
    /// The longest a fly-by waits for a break, in minutes.
    @Published var holdMinutes: Double {
        didSet { defaults.set(holdMinutes, forKey: "holdMinutes") }
    }
    @Published var meetingMode: Bool {
        didSet { defaults.set(meetingMode, forKey: "meetingMode") }
    }
    /// The gate to open while a call is on, if any.
    @Published var meetingGate: String {
        didSet { defaults.set(meetingGate, forKey: "meetingGate") }
    }

    func isUrgent(_ text: String) -> Bool {
        urgentWords.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { !$0.isEmpty && text.localizedCaseInsensitiveContains($0) }
    }

    /// The focused app in the open gate grows, its neighbours give way.
    @Published var squish: Bool {
        didSet { defaults.set(squish, forKey: "squish") }
    }
    /// How much the focused app grows: 0.25 is a quarter more room.
    @Published var squishAmount: Double {
        didSet { defaults.set(squishAmount, forKey: "squishAmount") }
    }
    /// Space around and between a gate's windows, where the tray shows; 0 is edge to edge.
    @Published var gateGap: Double {
        didSet { defaults.set(gateGap, forKey: "gateGap") }
    }
    /// Fingers for a sideways swipe that steps through gates; 0 is off.
    @Published var swipeFingers: Int {
        didSet { defaults.set(swipeFingers, forKey: "swipeFingers") }
    }
    /// Switching to an app that belongs to a gate opens the gate.
    @Published var autoOpen: Bool {
        didSet { defaults.set(autoOpen, forKey: "autoOpen") }
    }
    /// Shortcuts the user changed, by action; the rest use their standard keys.
    @Published var shortcuts: [String: Shortcut] {
        didSet {
            if let data = try? JSONEncoder().encode(shortcuts) { defaults.set(data, forKey: "shortcuts") }
        }
    }

    func shortcut(for action: ShortcutAction) -> Shortcut {
        shortcuts[action.rawValue] ?? action.standard
    }

    /// App pairs whose gate suggestion was dismissed, as "a|b".
    @Published var dismissedPairs: Set<String> {
        didSet { defaults.set(Array(dismissedPairs), forKey: "dismissedPairs") }
    }

    var thickness: CGFloat {
        switch (size, edge.isHorizontal) {
        case (.icons, _), (.names, true): 36
        case (.names, false): 160
        case (.large, true): 124
        case (.large, false): 180
        }
    }

    private init() {
        edge = StripEdge(rawValue: defaults.string(forKey: "stripEdge") ?? "") ?? .top
        size = StripSize(rawValue: defaults.string(forKey: "stripSize") ?? "") ?? .names
        hiddenApps = Set(defaults.stringArray(forKey: "hiddenApps") ?? [])
        keepClear = defaults.object(forKey: "keepClear") as? Bool ?? true
        flyBy = defaults.object(forKey: "flyBy") as? Bool ?? true
        flyByPreview = defaults.object(forKey: "flyByPreview") as? Bool ?? true
        flyBySeconds = defaults.object(forKey: "flyBySeconds") as? Double ?? 5
        flyByTrigger = FlyByTrigger(rawValue: defaults.string(forKey: "flyByTrigger") ?? "") ?? .mentions
        urgentWords = defaults.string(forKey: "urgentWords") ?? "urgent, asap, prod, outage"
        urgentMentions = defaults.object(forKey: "urgentMentions") as? Int ?? 5
        terminalFinished = defaults.object(forKey: "terminalFinished") as? Bool ?? true
        holdWhileFocused = defaults.object(forKey: "holdWhileFocused") as? Bool ?? true
        holdMinutes = defaults.object(forKey: "holdMinutes") as? Double ?? 3
        meetingMode = defaults.object(forKey: "meetingMode") as? Bool ?? true
        meetingGate = defaults.string(forKey: "meetingGate") ?? ""
        squish = defaults.object(forKey: "squish") as? Bool ?? true
        squishAmount = defaults.object(forKey: "squishAmount") as? Double ?? 0.25
        autoOpen = defaults.object(forKey: "autoOpen") as? Bool ?? false
        swipeFingers = defaults.object(forKey: "swipeFingers") as? Int ?? 0
        gateGap = defaults.object(forKey: "gateGap") as? Double ?? 6
        dismissedPairs = Set(defaults.stringArray(forKey: "dismissedPairs") ?? [])
        shortcuts = defaults.data(forKey: "shortcuts").flatMap { try? JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
    }
}
