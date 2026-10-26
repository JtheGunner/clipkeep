import Carbon.HIToolbox

/// A system-wide keyboard shortcut. It needs no permission; the handler runs on the main thread.
@MainActor
final class GlobalHotKey {
    /// Signature "CLPK".
    nonisolated static let hotKeyID = EventHotKeyID(signature: OSType(0x434C_504B), id: 1)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void

    /// Nil when the combination cannot be registered, for example because another app holds it.
    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
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
                // Another hotkey of this process is not ours.
                guard status == noErr, pressed.id == GlobalHotKey.hotKeyID.id,
                    pressed.signature == GlobalHotKey.hotKeyID.signature
                else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), Self.hotKeyID, GetApplicationEventTarget(), 0,
            &hotKeyRef)
        // On failure `deinit` still runs and removes the handler.
        guard registered == noErr else { return nil }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
