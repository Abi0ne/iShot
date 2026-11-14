import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// Image formats supported by the exporter.
enum ImageFormat: String, CaseIterable {
    case png
    case jpg

    var displayName: String { rawValue.uppercased() }
}

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct Hotkey: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Default combo for Capture Region: ⌥⇧A.
    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey | shiftKey))
    /// Default combo for Capture Fullscreen: ⌥⇧F.
    static let fullscreenDefault = Hotkey(keyCode: UInt32(kVK_ANSI_F), carbonModifiers: UInt32(optionKey | shiftKey))
    /// Default combo for Record Screen / Stop Recording: ⌥⇧R.
    static let recordDefault = Hotkey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(optionKey | shiftKey))

    /// Human-readable representation, e.g. "⌥⇧A".
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Hotkey.keyName(for: keyCode)
    }

    /// Builds a hotkey from an AppKit key event. Requires at least one modifier.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        guard mods != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = mods
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`"
    ]

    static func keyName(for keyCode: UInt32) -> String {
        keyNames[Int(keyCode)] ?? "Key\(keyCode)"
    }
}

/// Actions that have a global keyboard shortcut.
enum ShortcutAction: CaseIterable {
    case region, fullscreen, record

    var title: String {
        switch self {
        case .region: return "Capture Region"
        case .fullscreen: return "Capture Fullscreen"
        case .record: return "Record Screen"
        }
    }

    var settingsLabel: String {
        switch self {
        case .region: return "Region shortcut:"
        case .fullscreen: return "Fullscreen shortcut:"
        case .record: return "Recording shortcut:"
        }
    }

    var defaultHotkey: Hotkey {
        switch self {
        case .region: return .default
        case .fullscreen: return .fullscreenDefault
        case .record: return .recordDefault
        }
    }

    /// Capture Region always keeps a shortcut; the others can be turned off.
    var canBeTurnedOff: Bool { self != .region }

    /// Carbon hotkey id (unique per action).
    var hotkeyID: UInt32 {
        switch self {
        case .region: return 1
        case .fullscreen: return 2
        case .record: return 3
        }
    }
}

extension Notification.Name {
    static let settingsHotkeyChanged = Notification.Name("iShot.settingsHotkeyChanged")
}

/// UserDefaults-backed application settings.
final class SettingsStore {
    static let shared = SettingsStore()

    private enum Key {
        static let saveDir = "saveDir"
        static let format = "format"
        static let fileNamePrefix = "fileNamePrefix"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let launchAtLogin = "launchAtLogin"
        static let fullscreenKeyCode = "fullscreenHotkeyKeyCode"
        static let fullscreenModifiers = "fullscreenHotkeyModifiers"
        static let fullscreenDisabled = "fullscreenHotkeyDisabled"
        static let recordKeyCode = "recordHotkeyKeyCode"
        static let recordModifiers = "recordHotkeyModifiers"
        static let recordDisabled = "recordHotkeyDisabled"
        static let checkForUpdates = "checkForUpdates"
        static let skippedVersion = "skippedVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static var defaultSaveDir: String {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        return pictures.appendingPathComponent("Screenshots").path
    }

    var saveDir: String {
        get { defaults.string(forKey: Key.saveDir) ?? Self.defaultSaveDir }
        set { defaults.set(newValue, forKey: Key.saveDir) }
    }

    var saveDirURL: URL {
        URL(fileURLWithPath: (saveDir as NSString).expandingTildeInPath, isDirectory: true)
    }

    var format: ImageFormat {
        get { ImageFormat(rawValue: defaults.string(forKey: Key.format) ?? "") ?? .png }
        set { defaults.set(newValue.rawValue, forKey: Key.format) }
    }

    var fileNamePrefix: String {
        get {
            let value = defaults.string(forKey: Key.fileNamePrefix)?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? "iShot" : value
        }
        set { defaults.set(newValue, forKey: Key.fileNamePrefix) }
    }

    var hotkey: Hotkey {
        get {
            guard defaults.object(forKey: Key.hotkeyKeyCode) != nil else { return .default }
            return Hotkey(
                keyCode: UInt32(defaults.integer(forKey: Key.hotkeyKeyCode)),
                carbonModifiers: UInt32(defaults.integer(forKey: Key.hotkeyModifiers))
            )
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.hotkeyKeyCode)
            defaults.set(Int(newValue.carbonModifiers), forKey: Key.hotkeyModifiers)
            NotificationCenter.default.post(name: .settingsHotkeyChanged, object: self)
        }
    }

    /// Global shortcut for Capture Fullscreen; nil when turned off.
    var fullscreenHotkey: Hotkey? {
        get { optionalHotkey(Key.fullscreenKeyCode, Key.fullscreenModifiers, Key.fullscreenDisabled, default: .fullscreenDefault) }
        set { setOptionalHotkey(newValue, Key.fullscreenKeyCode, Key.fullscreenModifiers, Key.fullscreenDisabled) }
    }

    /// Global shortcut for Record Screen / Stop Recording; nil when turned off.
    var recordHotkey: Hotkey? {
        get { optionalHotkey(Key.recordKeyCode, Key.recordModifiers, Key.recordDisabled, default: .recordDefault) }
        set { setOptionalHotkey(newValue, Key.recordKeyCode, Key.recordModifiers, Key.recordDisabled) }
    }

    func hotkey(for action: ShortcutAction) -> Hotkey? {
        switch action {
        case .region: return hotkey
        case .fullscreen: return fullscreenHotkey
        case .record: return recordHotkey
        }
    }

    /// nil turns the shortcut off (ignored for Capture Region, which always has one).
    func setHotkey(_ value: Hotkey?, for action: ShortcutAction) {
        switch action {
        case .region: if let value { hotkey = value }
        case .fullscreen: fullscreenHotkey = value
        case .record: recordHotkey = value
        }
    }

    /// The other action already using `hotkey`, if any.
    func action(using hotkey: Hotkey, except action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self.hotkey(for: $0) == hotkey }
    }

    private func optionalHotkey(_ codeKey: String, _ modsKey: String, _ disabledKey: String, default value: Hotkey) -> Hotkey? {
        if defaults.bool(forKey: disabledKey) { return nil }
        guard defaults.object(forKey: codeKey) != nil else { return value }
        return Hotkey(keyCode: UInt32(defaults.integer(forKey: codeKey)),
                      carbonModifiers: UInt32(defaults.integer(forKey: modsKey)))
    }

    private func setOptionalHotkey(_ value: Hotkey?, _ codeKey: String, _ modsKey: String, _ disabledKey: String) {
        if let value {
            defaults.set(false, forKey: disabledKey)
            defaults.set(Int(value.keyCode), forKey: codeKey)
            defaults.set(Int(value.carbonModifiers), forKey: modsKey)
        } else {
            defaults.set(true, forKey: disabledKey)
        }
        NotificationCenter.default.post(name: .settingsHotkeyChanged, object: self)
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    /// Check GitHub for a newer release at launch (default: on).
    var checkForUpdates: Bool {
        get { defaults.object(forKey: Key.checkForUpdates) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.checkForUpdates) }
    }

    /// A release the user chose to skip in the update prompt.
    var skippedVersion: String? {
        get { defaults.string(forKey: Key.skippedVersion) }
        set { defaults.set(newValue, forKey: Key.skippedVersion) }
    }

    /// Registers/unregisters the app as a login item. Throws if the system refuses.
    func applyLaunchAtLogin(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else {
            if service.status == .enabled { try service.unregister() }
        }
        launchAtLogin = enabled
    }
}
