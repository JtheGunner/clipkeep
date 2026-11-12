import Carbon.HIToolbox

/// A system-wide keyboard shortcut. It needs no permission; the handler runs on the main thread.
@MainActor
final class GlobalHotKey {
    /// Signature "CLPK".
    nonisolated static let signature = OSType(0x434C_504B)

    /// Tells the hotkeys of this process apart; every instance needs its own.
    nonisolated let identifier: UInt32

    // Only touched in `init` and `deinit`, never concurrently.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Nil when the combination cannot be registered, for example because another app holds it.
    init?(
        identifier: UInt32, keyCode: Int, modifiers: Int,
        action: @escaping @MainActor () -> Void
    ) {
        self.identifier = identifier
        self.action = action
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil,
                    &pressed)
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                // Another hotkey of this process is not ours; it goes on to the next handler.
                guard status == noErr, pressed.id == hotKey.identifier,
                    pressed.signature == GlobalHotKey.signature
                else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers),
            EventHotKeyID(signature: Self.signature, id: identifier), GetApplicationEventTarget(),
            0, &hotKeyRef)
        // On failure `deinit` still runs and removes the handler.
        guard registered == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
