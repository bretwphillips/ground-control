import AppKit

/// Reads raw trackpad touches to catch a sideways swipe with a set number of fingers. Apps can't
/// see trackpad swipes outside their own windows, so this uses the private MultitouchSupport
/// framework, as gesture apps like BetterTouchTool do. It needs no permission; if a macOS update
/// changes the framework, swiping just stops working.
final class SwipeWatcher {
    enum Scrub {
        /// Toward the gate this many places along: 1 for a swipe to the left, -1 to the right.
        case began(Int)
        /// How far, 0 to 1, a fifth of the trackpad past where it started being all the way.
        case moved(CGFloat)
        /// Lifted: whether it went far enough, or fast enough, to go there.
        case ended(commit: Bool)
    }

    var onScrub: ((Scrub) -> Void)?
    var fingers = 0

    static let shared = SwipeWatcher()

    /// Where each finger was when the swipe began, by the framework's id for it.
    private var begun: (at: Double, points: [Int32: MTPoint])?
    private var fired = false
    private var started = false
    /// The swipe under way: which way, how far, and how fast it was last moving.
    private var scrub: (step: Int, progress: Float, at: Double, speed: Float)?

    func start() {
        guard !started, let framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createList = dlsym(framework, "MTDeviceCreateList"),
              let register = dlsym(framework, "MTRegisterContactFrameCallback"),
              let startDevice = dlsym(framework, "MTDeviceStart") else {
            log.error("swipes: MultitouchSupport isn't available")
            return
        }
        started = true
        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>
        typealias Register = @convention(c) (UnsafeMutableRawPointer, ContactCallback) -> Void
        typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

        let devices = unsafeBitCast(createList, to: CreateList.self)().takeUnretainedValue() as [AnyObject]
        for device in devices {
            let pointer = Unmanaged.passUnretained(device).toOpaque()
            unsafeBitCast(register, to: Register.self)(pointer, contactFrame)
            unsafeBitCast(startDevice, to: Start.self)(pointer, 0)
        }
        log.notice("swipes: watching \(devices.count) trackpad(s), touch size \(MemoryLayout<MTTouch>.stride)")
    }

    /// A swipe starts once the same fingers all move one way, mostly sideways, a little within a
    /// moment, and from then on follows them until they lift. A finger landing or lifting ends it,
    /// so a thumb or palm joining a scroll isn't measured against where the scroll began; lifting
    /// them all allows the next swipe.
    fileprivate func frame(_ touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        guard fingers > 0, let touches, count > 0 else {
            finish()
            begun = nil
            fired = false
            return
        }
        guard count == fingers else {
            finish()
            begun = nil
            return
        }
        let now = touches[0].timestamp
        let points = Dictionary((0..<count).map { (touches[$0].identifier, touches[$0].normalized.position) }) { a, _ in a }
        guard !fired else { return }
        guard let begun, Set(begun.points.keys) == Set(points.keys) else {
            finish()
            self.begun = (now, points)
            return
        }
        let moves = points.compactMap { id, p in begun.points[id].map { (dx: p.x - $0.x, dy: p.y - $0.y) } }
        let dx = moves.reduce(Float(0)) { $0 + $1.dx } / Float(moves.count)
        let dy = moves.reduce(Float(0)) { $0 + $1.dy } / Float(moves.count)

        if var current = scrub {
            // Like moving between desktops: swiping left brings the next one in from the right.
            let progress = Self.progress(-dx * Float(current.step))
            let elapsed = Float(now - current.at)
            if elapsed > 0 { current.speed = current.speed * 0.5 + (progress - current.progress) / elapsed * 0.5 }
            current.progress = progress
            current.at = now
            scrub = current
            DispatchQueue.main.async { self.onScrub?(.moved(CGFloat(progress))) }
            return
        }
        guard now - begun.at < 0.6 else {
            self.begun = (now, points)
            return
        }
        guard abs(dx) > 0.03, abs(dx) > 2 * abs(dy),
              moves.allSatisfy({ $0.dx * dx > 0 && abs($0.dx) > 0.015 }) else { return }
        let step = dx < 0 ? 1 : -1
        let progress = Self.progress(abs(dx))
        scrub = (step, progress, now, 0)
        DispatchQueue.main.async {
            self.onScrub?(.began(step))
            self.onScrub?(.moved(CGFloat(progress)))
        }
    }

    /// Counted from where the swipe was noticed, so the gate starts from the edge, not partway in.
    private static func progress(_ distance: Float) -> Float {
        min(max((distance - 0.03) / 0.2, 0), 1)
    }

    /// Past halfway goes there; so does a flick still moving that way as it lifts.
    private func finish() {
        guard let current = scrub else { return }
        scrub = nil
        fired = true
        let commit = current.progress > 0.5 || (current.progress > 0.15 && current.speed > 2)
        DispatchQueue.main.async { self.onScrub?(.ended(commit: commit)) }
    }
}

fileprivate struct MTPoint {
    var x: Float
    var y: Float
}

fileprivate struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

/// One finger on the trackpad, laid out as MultitouchSupport reports it.
fileprivate struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var finger: Int32
    var hand: Int32
    var normalized: MTVector
    var size: Float
    var pressure: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var millimeters: MTVector
    var reserved: (Int32, Int32)
    var density: Float
}

fileprivate typealias ContactCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

/// Called on the framework's own thread for every frame of touches.
private let contactFrame: ContactCallback = { _, touches, count, _, _ in
    SwipeWatcher.shared.frame(touches?.assumingMemoryBound(to: MTTouch.self), count: Int(count))
    return 0
}
