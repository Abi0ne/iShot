import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hotkey through Carbon's `RegisterEventHotKey`.
/// Call `register(_:)` again to replace the combo; the previous one is unregistered first.
final class GlobalShortcut {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let handler: () -> Void
    private static let signature: OSType = 0x6953_6874 // 'iSht'

    init(handler: @escaping () -> Void) {
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
        let id = EventHotKeyID(signature: Self.signature, id: 1)
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
            guard status == noErr, hotKeyID.signature == GlobalShortcut.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let me = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.handler() }
            return noErr
        }, 1, &spec, userData, &handlerRef)
    }
}
