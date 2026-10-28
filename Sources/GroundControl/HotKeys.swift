import Carbon

/// ⌃⌥1 to ⌃⌥9 open gates 1 to 9 and ⌃⌥Tab flips back to the previous one. Carbon hot keys need
/// no permission.
final class HotKeys {
    var onGate: ((Int) -> Void)?
    var onPreviousGate: (() -> Void)?

    private static let previous: UInt32 = 100

    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            if id.id == HotKeys.previous {
                keys.onPreviousGate?()
            } else {
                keys.onGate?(Int(id.id))
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4743_5452), id: UInt32(index))
            RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4743_5452), id: Self.previous)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }
}
