import AppKit

/// AppKit settings window: save folder, format, file-name prefix, hotkey, launch at login.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private let store = SettingsStore.shared
    private let folderField = NSTextField()
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let prefixField = NSTextField()
    private let hotkeyRecorder = HotkeyRecorderButton()
    private let launchCheckbox = NSButton(checkboxWithTitle: "Launch iShot at login", target: nil, action: nil)
    private let updatesCheckbox = NSButton(checkboxWithTitle: "Check for updates when iShot opens", target: nil, action: nil)
    private let previewLabel = NSTextField(labelWithString: "")

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "iShot Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI

    private func buildUI(in window: NSWindow) {
        folderField.isEditable = false
        folderField.lineBreakMode = .byTruncatingMiddle
        folderField.translatesAutoresizingMaskIntoConstraints = false
        folderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let revealButton = NSButton(title: "Show", target: self, action: #selector(revealFolder))
        let folderRow = NSStackView(views: [folderField, chooseButton, revealButton])
        folderRow.spacing = 6

        for format in ImageFormat.allCases { formatPopup.addItem(withTitle: format.displayName) }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)

        prefixField.placeholderString = "iShot"
        prefixField.delegate = self
        prefixField.translatesAutoresizingMaskIntoConstraints = false
        prefixField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.font = .systemFont(ofSize: 11)
        let prefixRow = NSStackView(views: [prefixField, previewLabel])
        prefixRow.spacing = 8

        hotkeyRecorder.onChange = { [weak self] hotkey in
            self?.store.hotkey = hotkey
        }
        let resetHotkey = NSButton(title: "Reset", target: self, action: #selector(resetHotkey))
        let hotkeyRow = NSStackView(views: [hotkeyRecorder, resetHotkey])
        hotkeyRow.spacing = 6

        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchChanged)
        updatesCheckbox.target = self
        updatesCheckbox.action = #selector(updatesChanged)
        let checkNow = NSButton(title: "Check Now", target: self, action: #selector(checkForUpdatesNow))
        let version = NSTextField(labelWithString: "Version \(Updater.shared.currentVersion)")
        version.textColor = .secondaryLabelColor
        version.font = .systemFont(ofSize: 11)
        let updatesRow = NSStackView(views: [updatesCheckbox, checkNow, version])
        updatesRow.spacing = 8

        let grid = NSGridView(views: [
            [label("Save to:"), folderRow],
            [label("Format:"), formatPopup],
            [label("File name prefix:"), prefixRow],
            [label("Capture shortcut:"), hotkeyRow],
            [label("Startup:"), launchCheckbox],
            [label("Updates:"), updatesRow]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString:
            "Capturing and recording require the Screen Recording permission (System Settings › Privacy & Security).")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.translatesAutoresizingMaskIntoConstraints = false

        let content = window.contentView!
        content.addSubview(grid)
        content.addSubview(note)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            note.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func loadValues() {
        folderField.stringValue = (store.saveDir as NSString).abbreviatingWithTildeInPath
        formatPopup.selectItem(at: ImageFormat.allCases.firstIndex(of: store.format) ?? 0)
        prefixField.stringValue = store.fileNamePrefix
        hotkeyRecorder.hotkey = store.hotkey
        launchCheckbox.state = store.launchAtLogin ? .on : .off
        updatesCheckbox.state = store.checkForUpdates ? .on : .off
        updatePreview()
    }

    private func updatePreview() {
        previewLabel.stringValue = "e.g. " + Exporter.fileName(prefix: store.fileNamePrefix, ext: store.format.rawValue)
    }

    // MARK: - Actions

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = store.saveDirURL
        panel.prompt = "Choose"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.store.saveDir = url.path
            self.loadValues()
        }
    }

    @objc private func revealFolder() {
        let url = store.saveDirURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func formatChanged() {
        store.format = ImageFormat.allCases[formatPopup.indexOfSelectedItem]
        updatePreview()
    }

    @objc private func resetHotkey() {
        store.hotkey = .default
        hotkeyRecorder.hotkey = .default
    }

    @objc private func updatesChanged() {
        store.checkForUpdates = updatesCheckbox.state == .on
    }

    @objc private func checkForUpdatesNow() {
        Updater.shared.checkNow()
    }

    @objc private func launchChanged() {
        let enabled = launchCheckbox.state == .on
        do {
            try store.applyLaunchAtLogin(enabled)
        } catch {
            launchCheckbox.state = enabled ? .off : .on
            let alert = NSAlert()
            alert.messageText = "Could not change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nMove iShot.app to /Applications and try again."
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        store.fileNamePrefix = prefixField.stringValue
        updatePreview()
    }

    func windowWillClose(_ notification: Notification) {
        hotkeyRecorder.stopRecording()
    }
}

/// Button that records the next key combo pressed while it is active.
final class HotkeyRecorderButton: NSButton {
    var hotkey: Hotkey = .default { didSet { refreshTitle() } }
    var onChange: ((Hotkey) -> Void)?

    private var monitor: Any?
    private var isRecording: Bool { monitor != nil }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        title = "Press shortcut… (Esc cancels)"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                self.stopRecording()
                return nil
            }
            if let combo = Hotkey(event: event) {
                self.hotkey = combo
                self.onChange?(combo)
                self.stopRecording()
            } else {
                NSSound.beep() // needs at least one modifier
            }
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        refreshTitle()
    }

    private func refreshTitle() {
        title = isRecording ? "Press shortcut… (Esc cancels)" : hotkey.displayString
    }
}
