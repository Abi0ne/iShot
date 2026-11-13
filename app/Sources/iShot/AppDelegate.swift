import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: StatusMenu!
    private var shortcut: GlobalShortcut?
    private var overlay: RegionOverlay?
    private let recorder = ScreenRecorder()
    private let settings = SettingsStore.shared

    /// Most recent screenshot (raw capture, replaced by the annotated version once exported).
    private var lastScreenshot: CGImage?
    /// Pixels per point of `lastScreenshot` (2 on Retina).
    private var lastScreenshotScale: CGFloat = 1

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupStatusItem()

        shortcut = GlobalShortcut { [weak self] in self?.perform(.captureRegion) }
        registerHotkey(showErrors: false)
        NotificationCenter.default.addObserver(forName: .settingsHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotkey(showErrors: true)
        }

        recorder.onUnexpectedStop = { [weak self] error in
            self?.updateStatusIcon()
            self?.showAlert(title: "Recording stopped", message: error.localizedDescription)
        }

        Updater.shared.checkOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut?.unregister()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu = StatusMenu { [weak self] command in self?.perform(command) }
        statusMenu.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        statusMenu.hasLastScreenshot = { [weak self] in self?.lastScreenshot != nil }
        statusItem.menu = statusMenu.menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let recording = recorder.isRecording
        let image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "camera.viewfinder",
                            accessibilityDescription: "iShot")
        image?.isTemplate = !recording
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        statusItem.button?.toolTip = recording ? "iShot — recording" : "iShot"
    }

    /// Accessory apps have no visible menu bar, but a main menu is still needed for the standard
    /// Edit key equivalents (⌘C/⌘V/⌘A…) to work inside text fields.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit iShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func registerHotkey(showErrors: Bool) {
        let hotkey = settings.hotkey
        statusMenu.updateHotkey(hotkey)
        let ok = shortcut?.register(hotkey) ?? false
        if !ok && showErrors {
            showAlert(title: "Shortcut unavailable",
                      message: "\(hotkey.displayString) could not be registered — it may be used by another app. Choose a different combination in Settings.")
        }
    }

    // MARK: - Commands

    private func perform(_ command: MenuCommand) {
        switch command {
        case .captureRegion: captureRegion()
        case .captureFullscreen: captureFullscreen()
        case .toggleRecording: toggleRecording()
        case .ocrLastScreenshot: ocrLastScreenshot()
        case .settings: SettingsWindowController.shared.present()
        case .checkForUpdates: Updater.shared.checkNow()
        case .about: showAbout()
        case .quit: NSApp.terminate(nil)
        }
    }

    private func ensureCapturePermission() -> Bool {
        if ScreenCapture.hasPermission { return true }
        ScreenCapture.requestPermission()
        if ScreenCapture.hasPermission { return true }
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission required"
        alert.informativeText = """
            Allow iShot in System Settings › Privacy & Security › Screen & System Audio Recording, \
            then relaunch iShot: macOS applies the permission only after a relaunch.

            If iShot is already enabled there, remove it with “−” and allow it again.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch iShot")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: openScreenRecordingSettings()
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
        return false
    }

    /// Starts a fresh copy of the bundle once this process has exited, then quits.
    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func captureRegion() {
        guard overlay == nil, ensureCapturePermission() else { return }
        let overlay = RegionOverlay()
        self.overlay = overlay
        overlay.begin { [weak self] result in
            guard let self else { return }
            self.overlay = nil
            guard let result else { return }
            // Let the overlay windows disappear from the screen before grabbing pixels.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                switch result {
                case let .region(rect): self.captureAndEdit(appKitRect: rect)
                case let .window(target): self.captureWindowAndEdit(target)
                }
            }
        }
    }

    private func captureWindowAndEdit(_ target: WindowTarget) {
        Task { @MainActor in
            do {
                let image = try await ScreenCapture.captureWindow(target.id)
                openEditor(with: image, scale: CGFloat(image.width) / max(target.frame.width, 1))
            } catch {
                showCaptureError(error, fallback: "The window could not be captured.")
            }
        }
    }

    private func captureAndEdit(appKitRect rect: NSRect) {
        let cgRect = ScreenCapture.cgRect(fromAppKit: rect)
        Task { @MainActor in
            do {
                let image = try await ScreenCapture.capture(globalRect: cgRect)
                // Image pixels per point (2 on Retina) so the editor shows it at its real size.
                let scale = CGFloat(image.width) / max(rect.width, 1)
                openEditor(with: image, scale: scale)
            } catch {
                showCaptureError(error, fallback: "The selected area could not be captured.")
            }
        }
    }

    private func captureFullscreen() {
        guard ensureCapturePermission() else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        Task { @MainActor in
            do {
                let image = try await ScreenCapture.captureDisplay(screen.displayID ?? CGMainDisplayID())
                openEditor(with: image, scale: CGFloat(image.width) / screen.frame.width)
            } catch {
                showCaptureError(error, fallback: "The screen could not be captured.")
            }
        }
    }

    private func showCaptureError(_ error: Error, fallback: String) {
        // A TCC denial from ScreenCaptureKit means the permission is missing or stale.
        if !ScreenCapture.hasPermission {
            _ = ensureCapturePermission()
        } else {
            showAlert(title: "Capture failed", message: "\(fallback)\n\(error.localizedDescription)")
        }
    }

    private func openEditor(with image: CGImage, scale: CGFloat) {
        lastScreenshot = image
        lastScreenshotScale = scale
        EditorWindowController.show(image: image, scale: scale) { [weak self] final in
            self?.lastScreenshot = final
        }
    }

    private func ocrLastScreenshot() {
        guard let image = lastScreenshot else {
            showAlert(title: "No screenshot yet", message: "Capture a region or the full screen first.")
            return
        }
        // Open the shot in the editor with its text selectable in place (Live Text).
        let controller = EditorWindowController.show(image: image, scale: lastScreenshotScale) { [weak self] final in
            self?.lastScreenshot = final
        }
        controller.startTextRecognition()
    }

    private func toggleRecording() {
        if recorder.isRecording {
            Task { @MainActor in
                do {
                    let url = try await recorder.stop()
                    updateStatusIcon()
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    updateStatusIcon()
                    showAlert(title: "Recording failed", message: error.localizedDescription)
                }
            }
        } else {
            Task { @MainActor in
                do {
                    try await recorder.start(saveDirectory: settings.saveDirURL, prefix: settings.fileNamePrefix)
                    updateStatusIcon()
                } catch RecorderError.permissionDenied {
                    updateStatusIcon()
                    let alert = NSAlert()
                    alert.messageText = "Screen Recording permission required"
                    alert.informativeText = RecorderError.permissionDenied.localizedDescription
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Cancel")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
                } catch {
                    updateStatusIcon()
                    showAlert(title: "Could not start recording", message: error.localizedDescription)
                }
            }
        }
    }

    private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "iShot",
            .credits: NSAttributedString(string: "Menu-bar screenshot tool: capture, annotate, OCR, pin, share and record.\nShortcut: \(settings.hotkey.displayString)")
        ])
    }

    // MARK: - Helpers

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
