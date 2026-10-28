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

final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var edge: StripEdge {
        didSet { defaults.set(edge.rawValue, forKey: "stripEdge") }
    }

    /// Bundle ids the user has taken off the strip.
    @Published var hiddenApps: Set<String> {
        didSet { defaults.set(Array(hiddenApps), forKey: "hiddenApps") }
    }

    let thickness: CGFloat = 32

    private init() {
        edge = StripEdge(rawValue: defaults.string(forKey: "stripEdge") ?? "") ?? .top
        hiddenApps = Set(defaults.stringArray(forKey: "hiddenApps") ?? [])
    }
}
