import AppKit

/// AppKit settings window: save folder, format, file-name prefix, shortcuts, launch at login, updates.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = SettingsWindowController()

    private let store = SettingsStore.shared
    private let folderField = NSTextField()
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let prefixField = NSTextField()
    private var recorders: [ShortcutAction: HotkeyRecorderButton] = [:]
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

        var shortcutRows: [[NSView]] = []
        for (index, action) in ShortcutAction.allCases.enumerated() {
            let recorder = HotkeyRecorderButton()
            recorder.onChange = { [weak self] hotkey in self?.shortcutRecorded(hotkey, for: action) }
            recorders[action] = recorder

            let reset = NSButton(title: "Reset", target: self, action: #selector(resetShortcut(_:)))
            reset.tag = index
            reset.toolTip = "Restore \(action.defaultHotkey.displayString)"
            var views: [NSView] = [recorder, reset]
            if action.canBeTurnedOff {
                let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut(_:)))
                clear.tag = index
                clear.toolTip = "Turn off the shortcut for \(action.title)"
                views.append(clear)
            }
            let row = NSStackView(views: views)
            row.spacing = 6
            shortcutRows.append([label(action.settingsLabel), row])
        }

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
        let reportButton = NSButton(title: "Report a Problem…", target: self, action: #selector(reportProblem))

        let grid = NSGridView(views: [
            [label("Save to:"), folderRow],
            [label("Format:"), formatPopup],
            [label("File name prefix:"), prefixRow]
        ] + shortcutRows + [
            [label("Startup:"), launchCheckbox],
            [label("Updates:"), updatesRow],
            [label("Help:"), reportButton]
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
        for (action, recorder) in recorders { recorder.hotkey = store.hotkey(for: action) }
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

    private func shortcutRecorded(_ hotkey: Hotkey, for action: ShortcutAction) {
        if let other = store.action(using: hotkey, except: action) {
            rejectDuplicate(hotkey, usedBy: other.title)
            recorders[action]?.hotkey = store.hotkey(for: action)
            return
        }
        store.setHotkey(hotkey, for: action)
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        let action = ShortcutAction.allCases[sender.tag]
        let hotkey = action.defaultHotkey
        if let other = store.action(using: hotkey, except: action) {
            rejectDuplicate(hotkey, usedBy: other.title)
            return
        }
        store.setHotkey(hotkey, for: action)
        recorders[action]?.hotkey = hotkey
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        let action = ShortcutAction.allCases[sender.tag]
        store.setHotkey(nil, for: action)
        recorders[action]?.hotkey = nil
    }

    private func rejectDuplicate(_ hotkey: Hotkey, usedBy action: String) {
        let alert = NSAlert()
        alert.messageText = "Shortcut already in use"
        alert.informativeText = "\(hotkey.displayString) is already the shortcut for \(action). Choose a different combination."
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @objc private func updatesChanged() {
        store.checkForUpdates = updatesCheckbox.state == .on
    }

    @objc private func reportProblem() {
        ReportWindowController.present(crashed: false)
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
        recorders.values.forEach { $0.stopRecording() }
    }
}

/// Button that records the next key combo pressed while it is active.
final class HotkeyRecorderButton: NSButton {
    /// nil shows "None" (shortcut turned off).
    var hotkey: Hotkey? = .default { didSet { refreshTitle() } }
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
        title = isRecording ? "Press shortcut… (Esc cancels)" : (hotkey?.displayString ?? "None")
    }
}
