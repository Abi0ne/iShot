import AppKit
import Carbon.HIToolbox

/// Registers one system-wide hotkey through Carbon's `RegisterEventHotKey`.
/// Several instances can coexist: each has its own `id` and only reacts to its own hotkey.
/// Call `register(_:)` again to replace the combo; the previous one is unregistered first.
final class GlobalShortcut {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private let id: UInt32
    private static let signature: OSType = 0x6953_6874 // 'iSht'

    init(id: UInt32, handler: @escaping () -> Void) {
        self.id = id
        self.handler = handler
        installEventHandler()
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers the combo. Returns false if the system rejected it (e.g. already taken).
    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: Self.signature, id: self.id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("iShot: RegisterEventHotKey failed (\(status)) for \(hotkey.displayString)")
            return false
        }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let me = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
            // Not ours: let the next handler (another GlobalShortcut) take it.
            guard status == noErr, hotKeyID.signature == GlobalShortcut.signature, hotKeyID.id == me.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { me.handler() }
            return noErr
        }, 1, &spec, userData, &handlerRef)
    }
}
