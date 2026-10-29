import AppKit
import Combine

/// Holds every fly-by by hand, for deep work that isn't typing (reading, thinking). Urgent ones
/// still come through, as when focused; held ones come when it ends.
final class GroundStop: ObservableObject {
    static let shared = GroundStop()

    /// When it ends; `.distantFuture` until it's turned off.
    @Published private(set) var until: Date?
    private var timer: Timer?

    var active: Bool { until.map { $0 > Date() } ?? false }

    func start(for minutes: Double?) {
        until = minutes.map { Date().addingTimeInterval($0 * 60) } ?? .distantFuture
        log.notice("ground stop until \(String(describing: self.until), privacy: .public)")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, !active else { return }
            end()
        }
    }

    func end() {
        timer?.invalidate()
        timer = nil
        until = nil
        log.notice("ground stop ended")
    }

    /// For the menu: "until 3:30 PM", or "until turned off".
    var description: String {
        guard let until, active else { return "" }
        if until == .distantFuture { return "until turned off" }
        return "until " + until.formatted(date: .omitted, time: .shortened)
    }
}
