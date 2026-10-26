import Carbon.HIToolbox

/// A system-wide keyboard shortcut. It needs no permission; the handler runs on the main thread.
@MainActor
final class GlobalHotKey {
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
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated { hotKey.action() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x434C_504B), id: 1)  // "CLPK"
        let registered = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
