import AppKit

/// Notices two apps the user keeps switching between, to suggest a gate with both side by side.
/// It only counts app switches, kept in memory for the last hour.
final class Patterns: ObservableObject {
    struct Pair: Equatable {
        let first: String
        let second: String

        var key: String { "\(first)|\(second)" }
    }

    @Published private(set) var suggestion: Pair?

    private let settings: Settings
    private let store: GateStore
    private var switches: [(key: String, at: Date)] = []
    private var last: String?
    /// Ten round trips in an hour.
    private let threshold = 20
    private let ignored: Set<String> = ["com.apple.finder", Bundle.main.bundleIdentifier ?? ""]

    init(settings: Settings, store: GateStore) {
        self.settings = settings
        self.store = store
    }

    func activated(_ id: String) {
        guard !ignored.contains(id) else { return }
        defer { last = id }
        guard let last, last != id else { return }
        let ids = [last, id].sorted()
        let pair = Pair(first: ids[0], second: ids[1])
        let hourAgo = Date().addingTimeInterval(-3600)
        switches.removeAll { $0.at < hourAgo }
        switches.append((pair.key, Date()))

        guard suggestion == nil,
              switches.filter({ $0.key == pair.key }).count >= threshold,
              !settings.dismissedPairs.contains(pair.key),
              !store.gates.contains(where: { Set($0.layout.leaves).isSuperset(of: ids) }) else { return }
        suggestion = pair
        log.notice("suggesting a gate for \(pair.key, privacy: .public)")
    }

    /// The suggested gate: the two apps side by side, the one in front on the left.
    func accept() -> Gate? {
        guard let pair = suggestion else { return nil }
        suggestion = nil
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ids = front == pair.second ? [pair.second, pair.first] : [pair.first, pair.second]
        let name = ids.map(AppIcon.name).joined(separator: " + ")
        return Gate(name: name, layout: .split(.columns, ids.map(GateLayout.app), [0.5, 0.5]))
    }

    func dismiss() {
        guard let pair = suggestion else { return }
        settings.dismissedPairs.insert(pair.key)
        suggestion = nil
    }
}
