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
    }
}
