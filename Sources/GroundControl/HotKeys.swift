import Carbon

/// Gate shortcuts, all on ⌃⌥ (⌃⌥ with the arrows belongs to window snappers like Magnet).
/// Carbon hot keys need no permission.
final class HotKeys {
    enum Action {
        /// ⌃⌥1 to ⌃⌥9: gates 1 to 9.
        case gate(Int)
        /// ⌃⌥Tab: the gate open before this one.
        case previousGate
        /// ⌃⌥[ and ⌃⌥]: the gate to the left or right in the strip, wrapping around.
        case stepGate(Int)
        /// ⌃⌥` and ⌃⌥⇧`: the next or previous app in the open gate, wrapping around.
        case stepApp(Int)
    }

    var onAction: ((Action) -> Void)?

    private var actions: [UInt32: Action] = [:]
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
            if let action = keys.actions[id.id] { keys.onAction?(action) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let base = UInt32(controlKey | optionKey)
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (index, key) in digits.enumerated() {
            register(key, base, .gate(index))
        }
        register(kVK_Tab, base, .previousGate)
        register(kVK_ANSI_LeftBracket, base, .stepGate(-1))
        register(kVK_ANSI_RightBracket, base, .stepGate(1))
        register(kVK_ANSI_Grave, base, .stepApp(1))
        register(kVK_ANSI_Grave, base | UInt32(shiftKey), .stepApp(-1))
    }

    private func register(_ key: Int, _ modifiers: UInt32, _ action: Action) {
        let number = UInt32(actions.count)
        actions[number] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), modifiers, EventHotKeyID(signature: OSType(0x4743_5452), id: number), GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }
}
