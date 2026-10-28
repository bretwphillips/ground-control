import AppKit

/// Reads raw trackpad touches to catch a sideways swipe with a set number of fingers. Apps can't
/// see trackpad swipes outside their own windows, so this uses the private MultitouchSupport
/// framework, as gesture apps like BetterTouchTool do. It needs no permission; if a macOS update
/// changes the framework, swiping just stops working.
final class SwipeWatcher {
    /// -1 for a swipe to the left, 1 to the right.
    var onSwipe: ((Int) -> Void)?
    var fingers = 0

    static let shared = SwipeWatcher()

    private var startX: Float?
    private var fired = false
    private var started = false

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

    /// Fires once per swipe, when the fingers' average has moved a sixth of the trackpad sideways.
    fileprivate func frame(_ touches: UnsafeMutablePointer<MTTouch>?, count: Int) {
        guard fingers > 0, let touches, count == fingers else {
            startX = nil
            fired = false
            return
        }
        let x = (0..<count).reduce(Float(0)) { $0 + touches[$1].normalized.position.x } / Float(count)
        guard let start = startX else {
            startX = x
            return
        }
        guard !fired, abs(x - start) > 0.16 else { return }
        fired = true
        // Like moving between desktops: swiping left brings the next one in from the right.
        let step = x < start ? 1 : -1
        DispatchQueue.main.async { self.onSwipe?(step) }
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
