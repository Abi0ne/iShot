import AppKit

/// Commands exposed by the status-bar menu.
enum MenuCommand {
    case captureRegion, captureFullscreen, toggleRecording, ocrLastScreenshot, settings, about, quit
}

/// Builds and updates the menu attached to the status item.
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let handler: (MenuCommand) -> Void

    private var captureRegionItem: NSMenuItem!
    private var recordItem: NSMenuItem!
    private var ocrItem: NSMenuItem!

    /// Queried each time the menu opens.
    var isRecording: () -> Bool = { false }
    var hasLastScreenshot: () -> Bool = { false }

    init(handler: @escaping (MenuCommand) -> Void) {
        self.handler = handler
        super.init()
        build()
    }

    private func build() {
        menu.delegate = self
        menu.autoenablesItems = false

        captureRegionItem = add("Capture Region", symbol: "crop", command: .captureRegion)
        add("Capture Fullscreen", symbol: "rectangle.dashed", command: .captureFullscreen)
        recordItem = add("Record Screen", symbol: "record.circle", command: .toggleRecording)
        menu.addItem(.separator())
        ocrItem = add("OCR Last Screenshot", symbol: "text.viewfinder", command: .ocrLastScreenshot)
        menu.addItem(.separator())
        add("Settings…", symbol: "gearshape", command: .settings, key: ",")
        add("Info", symbol: "info.circle", command: .about)
        menu.addItem(.separator())
        add("Quit iShot", symbol: nil, command: .quit, key: "q")
    }

    @discardableResult
    private func add(_ title: String, symbol: String?, command: MenuCommand, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(itemClicked(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = CommandBox(command)
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        menu.addItem(item)
        return item
    }

    /// Shows the configured global hotkey next to "Capture Region".
    func updateHotkey(_ hotkey: Hotkey) {
        captureRegionItem.title = "Capture Region\t\(hotkey.displayString)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let recording = isRecording()
        recordItem.title = recording ? "Stop Recording" : "Record Screen"
        recordItem.image = NSImage(systemSymbolName: recording ? "stop.circle.fill" : "record.circle",
                                   accessibilityDescription: recordItem.title)
        ocrItem.isEnabled = hasLastScreenshot()
    }

    @objc private func itemClicked(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        handler(box.command)
    }

    private final class CommandBox {
        let command: MenuCommand
        init(_ command: MenuCommand) { self.command = command }
    }
}
